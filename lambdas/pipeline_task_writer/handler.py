"""pipeline_task_writer — Step Functions Task.

Produces or revises a draft, called at two points in the content pipeline
state machine:

  mode="initial": first draft for a brand-new job. Invokes the Orchestrator
    agent runtime, which internally runs the full Writer<->Reviewer AI
    review loop (capped at max_ai_review_iterations, enforced inside the
    Orchestrator agent itself — see agents/orchestrator/agent.py) and
    returns structured initial_draft / ai_reviewed_draft fields.

  mode="revise": a human rejected the draft with feedback. Invokes the
    Writer agent runtime *directly* (bypassing the Orchestrator/AI-review
    loop) — a human already reviewed it, so there's no need to re-spend AI
    review rounds on every human revision request.

Either way, writes the resulting draft to DynamoDB (content_jobs — the
primary store the app reads from) and mirrors it to S3 as a permanent,
per-version artifact (see artifacts_bucket.tf for why: DynamoDB fields get
overwritten by later revisions, S3 keeps every version).
"""

import json
import os
from datetime import datetime, timezone

import boto3
from botocore.config import Config as BotocoreConfig

AWS_REGION = os.environ.get("AWS_REGION", "us-east-1")
WRITER_RUNTIME_ARN = os.environ["WRITER_RUNTIME_ARN"]
ORCHESTRATOR_RUNTIME_ARN = os.environ["ORCHESTRATOR_RUNTIME_ARN"]
CONTENT_JOBS_TABLE = os.environ["CONTENT_JOBS_TABLE"]
ARTIFACTS_BUCKET = os.environ["ARTIFACTS_BUCKET"]

# botocore's default read_timeout is 60s — far too short for this call.
# invoke_agent_runtime is synchronous/non-streaming: it returns zero bytes
# until the Orchestrator's *entire* draft->review loop finishes, which
# routinely takes 150-300s+. Without this, every real invocation raised
# ReadTimeoutError well before either the agent finished or this Lambda's
# own (480s) timeout ever had a chance to be the actual ceiling — silently
# failing every job before it could reach human review. Set just under this
# function's own timeout so that a *genuine* hang still hits Step Functions'
# Catch/MarkFailed via the Lambda timeout, rather than an ambiguous
# client-side error a few seconds earlier.
_agentcore = boto3.client(
    "bedrock-agentcore", region_name=AWS_REGION, config=BotocoreConfig(read_timeout=470, connect_timeout=10)
)
_s3 = boto3.client("s3", region_name=AWS_REGION)
_dynamodb = boto3.resource("dynamodb", region_name=AWS_REGION)
_jobs_table = _dynamodb.Table(CONTENT_JOBS_TABLE)


def _invoke_runtime(runtime_arn: str, payload: dict) -> dict:
    response = _agentcore.invoke_agent_runtime(
        agentRuntimeArn=runtime_arn,
        contentType="application/json",
        payload=json.dumps(payload).encode("utf-8"),
    )
    body = response["response"].read()
    return json.loads(body)


def _now() -> str:
    return datetime.now(timezone.utc).isoformat()


def _put_artifact(job_id: str, name: str, text: str) -> str:
    """Writes one draft version to S3, returns its key."""
    key = f"jobs/{job_id}/{name}.md"
    _s3.put_object(Bucket=ARTIFACTS_BUCKET, Key=key, Body=text.encode("utf-8"), ContentType="text/markdown")
    return key


def handler(event: dict, _context) -> dict:
    job_id = event["job_id"]
    brief = event["brief"]
    mode = event.get("mode", "initial")

    update_expr_parts = ["#status = :status", "updated_at = :updated_at"]
    expr_values = {":status": "pending_human_review", ":updated_at": _now()}
    expr_names = {"#status": "status"}

    if mode == "revise":
        previous_draft = event["previous_draft"]
        feedback = event["feedback"]
        prompt = (
            f"{brief}\n\nPrevious draft:\n{previous_draft}\n\n"
            f"Human reviewer feedback to address:\n{feedback}"
        )
        # Best-effort progress marker before the (single, ~30-60s) blocking
        # call — mirrors what the Orchestrator writes for itself in mode
        # "initial" (see agents/orchestrator/agent.py's _update_progress),
        # since this path calls the Writer directly and skips the
        # Orchestrator entirely.
        _jobs_table.update_item(
            Key={"job_id": job_id},
            UpdateExpression="SET current_step = :step",
            ExpressionAttributeValues={":step": "Writer agent is revising the draft…"},
        )
        result = _invoke_runtime(WRITER_RUNTIME_ARN, {"prompt": prompt})
        draft = result.get("result", "")

        revision_key = _put_artifact(job_id, f"revision-{event.get('human_review_round', 'n')}", draft)
        update_expr_parts += ["draft = :draft", "draft_s3_key = :draft_s3_key"]
        expr_values[":draft"] = draft
        expr_values[":draft_s3_key"] = revision_key
        ai_review_rounds = None
    else:
        result = _invoke_runtime(ORCHESTRATOR_RUNTIME_ARN, {"brief": brief, "job_id": job_id})
        initial_draft = result.get("initial_draft") or ""
        ai_reviewed_draft = result.get("ai_reviewed_draft") or ""
        draft = ai_reviewed_draft or initial_draft
        ai_review_rounds = result.get("ai_review_rounds")

        initial_key = _put_artifact(job_id, "initial_draft", initial_draft)
        ai_reviewed_key = _put_artifact(job_id, "ai_reviewed_draft", ai_reviewed_draft)

        update_expr_parts += [
            "initial_draft = :initial_draft",
            "initial_draft_s3_key = :initial_draft_s3_key",
            "ai_reviewed_draft = :ai_reviewed_draft",
            "ai_reviewed_draft_s3_key = :ai_reviewed_draft_s3_key",
            "draft = :draft",
            "draft_s3_key = :draft_s3_key",
            "ai_approved = :ai_approved",
        ]
        expr_values.update(
            {
                ":initial_draft": initial_draft,
                ":initial_draft_s3_key": initial_key,
                ":ai_reviewed_draft": ai_reviewed_draft,
                ":ai_reviewed_draft_s3_key": ai_reviewed_key,
                ":draft": draft,
                ":draft_s3_key": ai_reviewed_key,
                ":ai_approved": bool(result.get("approved")),
            }
        )
        if ai_review_rounds is not None:
            update_expr_parts.append("ai_review_rounds = :ai_review_rounds")
            expr_values[":ai_review_rounds"] = ai_review_rounds

    _jobs_table.update_item(
        Key={"job_id": job_id},
        UpdateExpression="SET " + ", ".join(update_expr_parts),
        ExpressionAttributeNames=expr_names,
        ExpressionAttributeValues=expr_values,
    )

    return {"draft": draft, "ai_review_rounds": ai_review_rounds}
