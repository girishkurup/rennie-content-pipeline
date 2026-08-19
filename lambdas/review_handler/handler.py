"""review_handler — API Gateway HTTP API endpoints.

POST /jobs/{job_id}/review   (reviewers group only)
  Body: {"approved": true} or {"approved": false, "feedback": "<what to fix>"}
  Resumes the Step Functions execution paused on this job's
  review_task_token (see lambdas/pipeline_task_reviewer) — the real
  counterpart to the `aws stepfunctions send-task-success` calls used to
  test the pipeline end-to-end before this lambda existed.

POST /jobs/{job_id}/stop   (the job's own requester, or any reviewer)
  Cancels the job's Step Functions execution at whatever stage it's
  currently in (queued, mid-AI-review, or paused awaiting human review) and
  marks the job "stopped". A stopped execution never reaches
  pipeline_finalize, so this handler updates DynamoDB directly instead of
  relying on the state machine to do it.
"""

import json
import os

import boto3

AWS_REGION = os.environ.get("AWS_REGION", "us-east-1")
CONTENT_JOBS_TABLE = os.environ["CONTENT_JOBS_TABLE"]

_dynamodb = boto3.resource("dynamodb", region_name=AWS_REGION)
_jobs = _dynamodb.Table(CONTENT_JOBS_TABLE)
_sfn = boto3.client("stepfunctions", region_name=AWS_REGION)


def _response(status: int, body: dict) -> dict:
    return {
        "statusCode": status,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(body),
    }


def _claims(event: dict) -> dict:
    return event.get("requestContext", {}).get("authorizer", {}).get("jwt", {}).get("claims", {})


def _groups(claims: dict) -> set:
    raw = claims.get("cognito:groups", "")
    return {g.strip() for g in raw.strip("[]").replace(",", " ").split() if g.strip()}


def _handle_review(event: dict, job_id: str) -> dict:
    claims = _claims(event)
    if "reviewers" not in _groups(claims):
        return _response(403, {"error": "Requires the reviewers group."})

    try:
        body = json.loads(event.get("body") or "{}")
    except json.JSONDecodeError:
        return _response(400, {"error": "Invalid JSON body."})

    approved = bool(body.get("approved"))
    feedback = body.get("feedback", "")

    result = _jobs.get_item(Key={"job_id": job_id})
    item = result.get("Item")
    if not item:
        return _response(404, {"error": "Job not found."})

    task_token = item.get("review_task_token")
    if not task_token:
        return _response(409, {"error": "This job isn't currently awaiting review."})

    human_review_rounds = int(item.get("human_review_rounds", 0))
    if not approved:
        human_review_rounds += 1
        _jobs.update_item(
            Key={"job_id": job_id},
            UpdateExpression="SET human_review_rounds = :rounds",
            ExpressionAttributeValues={":rounds": human_review_rounds},
        )

    _sfn.send_task_success(
        taskToken=task_token,
        output=json.dumps(
            {"approved": approved, "feedback": feedback, "human_review_rounds": human_review_rounds}
        ),
    )

    return _response(200, {"job_id": job_id, "approved": approved, "human_review_rounds": human_review_rounds})


def _handle_stop(event: dict, job_id: str) -> dict:
    claims = _claims(event)
    user_id = claims.get("sub")
    if not user_id:
        return _response(401, {"error": "Missing authenticated user."})

    result = _jobs.get_item(Key={"job_id": job_id})
    item = result.get("Item")
    if not item:
        return _response(404, {"error": "Job not found."})

    is_owner = item.get("user_id") == user_id
    is_reviewer = "reviewers" in _groups(claims)
    if not (is_owner or is_reviewer):
        return _response(403, {"error": "Only the requester or a reviewer can stop this job."})

    if item.get("status") in ("completed", "escalated", "stopped"):
        return _response(409, {"error": f"Job is already {item.get('status')}, nothing to stop."})

    execution_arn = item.get("execution_arn")
    if execution_arn:
        try:
            _sfn.stop_execution(executionArn=execution_arn, cause="Stopped by user via UI")
        except _sfn.exceptions.ExecutionDoesNotExist:
            pass  # already finished/stopped — fall through and just fix the DynamoDB status

    _jobs.update_item(
        Key={"job_id": job_id},
        UpdateExpression="SET #status = :status REMOVE review_task_token",
        ExpressionAttributeNames={"#status": "status"},
        ExpressionAttributeValues={":status": "stopped"},
    )

    return _response(200, {"job_id": job_id, "status": "stopped"})


def handler(event: dict, _context) -> dict:
    job_id = (event.get("pathParameters") or {}).get("job_id")
    if not job_id:
        return _response(400, {"error": "Missing job_id in path."})

    route = event.get("routeKey", "")
    if route == "POST /jobs/{job_id}/stop":
        return _handle_stop(event, job_id)
    return _handle_review(event, job_id)
