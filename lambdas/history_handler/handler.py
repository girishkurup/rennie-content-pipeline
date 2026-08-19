"""history_handler — API Gateway HTTP API endpoints (Cognito JWT authorizer, read-only).

GET /conversations                              -> caller's own conversations
GET /conversations/{conversation_id}/messages    -> that conversation's transcript
GET /jobs?status=pending_human_review            -> reviewer dashboard queue (by_status GSI)
GET /jobs/{job_id}                                -> a single job's current state
GET /jobs/{job_id}/artifacts/{stage}              -> presigned S3 URL to download that
                                                      stage's draft ("initial", "ai_reviewed",
                                                      "current", or "final")
"""

import json
import os

import boto3
from boto3.dynamodb.conditions import Key

AWS_REGION = os.environ.get("AWS_REGION", "us-east-1")
CONVERSATIONS_TABLE = os.environ["CONVERSATIONS_TABLE"]
MESSAGES_TABLE = os.environ["MESSAGES_TABLE"]
CONTENT_JOBS_TABLE = os.environ["CONTENT_JOBS_TABLE"]
ARTIFACTS_BUCKET = os.environ["ARTIFACTS_BUCKET"]

_dynamodb = boto3.resource("dynamodb", region_name=AWS_REGION)
_conversations = _dynamodb.Table(CONVERSATIONS_TABLE)
_messages = _dynamodb.Table(MESSAGES_TABLE)
_jobs = _dynamodb.Table(CONTENT_JOBS_TABLE)
_s3 = boto3.client("s3", region_name=AWS_REGION)

# Maps the frontend's stage names to the content_jobs attribute holding that
# stage's S3 key.
_STAGE_S3_KEY_FIELD = {
    "initial": "initial_draft_s3_key",
    "ai_reviewed": "ai_reviewed_draft_s3_key",
    "current": "draft_s3_key",
    "final": "final_draft_s3_key",
}


def _response(status: int, body: dict) -> dict:
    return {
        "statusCode": status,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(body, default=str),
    }


def _claims(event: dict) -> dict:
    return event.get("requestContext", {}).get("authorizer", {}).get("jwt", {}).get("claims", {})


def _groups(claims: dict) -> set:
    # HTTP API's JWT authorizer flattens the cognito:groups array claim to a
    # string like "[reviewers]" or "[requesters, reviewers]" — parse leniently.
    raw = claims.get("cognito:groups", "")
    return {g.strip() for g in raw.strip("[]").replace(",", " ").split() if g.strip()}


def handler(event: dict, _context) -> dict:
    claims = _claims(event)
    user_id = claims.get("sub")
    if not user_id:
        return _response(401, {"error": "Missing authenticated user."})

    route = event.get("routeKey", "")
    params = event.get("pathParameters") or {}
    query = event.get("queryStringParameters") or {}

    if route == "GET /conversations":
        result = _conversations.query(KeyConditionExpression=Key("user_id").eq(user_id))
        return _response(200, {"conversations": result.get("Items", [])})

    if route == "GET /conversations/{conversation_id}/messages":
        result = _messages.query(KeyConditionExpression=Key("conversation_id").eq(params["conversation_id"]))
        return _response(200, {"messages": result.get("Items", [])})

    if route == "GET /jobs":
        if "reviewers" not in _groups(claims):
            return _response(403, {"error": "Reviewer dashboard access requires the reviewers group."})
        status = query.get("status", "pending_human_review")
        result = _jobs.query(
            IndexName="by_status",
            KeyConditionExpression=Key("status").eq(status),
            ScanIndexForward=False,  # most-recently-updated first
        )
        return _response(200, {"jobs": result.get("Items", [])})

    if route == "GET /jobs/{job_id}":
        result = _jobs.get_item(Key={"job_id": params["job_id"]})
        item = result.get("Item")
        if not item:
            return _response(404, {"error": "Job not found."})
        return _response(200, item)

    if route == "GET /jobs/{job_id}/artifacts/{stage}":
        stage = params.get("stage", "")
        field = _STAGE_S3_KEY_FIELD.get(stage)
        if field is None:
            return _response(400, {"error": f"Unknown stage '{stage}'. Valid: {list(_STAGE_S3_KEY_FIELD)}"})

        result = _jobs.get_item(Key={"job_id": params["job_id"]})
        item = result.get("Item")
        if not item:
            return _response(404, {"error": "Job not found."})

        s3_key = item.get(field)
        if not s3_key:
            return _response(404, {"error": f"No '{stage}' artifact for this job yet."})

        url = _s3.generate_presigned_url(
            "get_object",
            Params={"Bucket": ARTIFACTS_BUCKET, "Key": s3_key},
            ExpiresIn=300,
        )
        return _response(200, {"download_url": url, "expires_in": 300})

    return _response(404, {"error": f"Unknown route: {route}"})
