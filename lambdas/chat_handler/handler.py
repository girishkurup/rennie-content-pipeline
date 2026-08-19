"""chat_handler — API Gateway HTTP API endpoint (Cognito JWT authorizer).

POST /chat
Body: {"message": "<content brief>", "conversation_id": "<optional>"}

Any authenticated user (the "requesters" group in Cognito) can call this. It
creates (or resumes) a conversation, records the user's message, creates a
new content_jobs record, and starts a Step Functions execution
(pipeline_orchestration) for it — that state machine is what actually
produces and reviews the draft; this lambda's job is just to kick it off and
persist the chat-history side of things.
"""

import json
import os
import uuid
from datetime import datetime, timezone

import boto3

AWS_REGION = os.environ.get("AWS_REGION", "us-east-1")
CONVERSATIONS_TABLE = os.environ["CONVERSATIONS_TABLE"]
MESSAGES_TABLE = os.environ["MESSAGES_TABLE"]
CONTENT_JOBS_TABLE = os.environ["CONTENT_JOBS_TABLE"]
STATE_MACHINE_ARN = os.environ["STATE_MACHINE_ARN"]

_dynamodb = boto3.resource("dynamodb", region_name=AWS_REGION)
_conversations = _dynamodb.Table(CONVERSATIONS_TABLE)
_messages = _dynamodb.Table(MESSAGES_TABLE)
_jobs = _dynamodb.Table(CONTENT_JOBS_TABLE)
_sfn = boto3.client("stepfunctions", region_name=AWS_REGION)


def _now() -> str:
    return datetime.now(timezone.utc).isoformat()


def _response(status: int, body: dict) -> dict:
    return {
        "statusCode": status,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(body),
    }


def handler(event: dict, _context) -> dict:
    claims = event.get("requestContext", {}).get("authorizer", {}).get("jwt", {}).get("claims", {})
    user_id = claims.get("sub")
    if not user_id:
        return _response(401, {"error": "Missing authenticated user."})

    try:
        body = json.loads(event.get("body") or "{}")
    except json.JSONDecodeError:
        return _response(400, {"error": "Invalid JSON body."})

    message = (body.get("message") or "").strip()
    if not message:
        return _response(400, {"error": "Missing 'message' in request body."})

    conversation_id = body.get("conversation_id") or str(uuid.uuid4())
    now = _now()

    # Upsert: works whether this is a brand-new conversation or a reply in
    # an existing one, without a separate "does it exist" read first.
    _conversations.update_item(
        Key={"user_id": user_id, "conversation_id": conversation_id},
        UpdateExpression="SET last_message_at = :now, created_at = if_not_exists(created_at, :now)",
        ExpressionAttributeValues={":now": now},
    )

    message_id = str(uuid.uuid4())
    _messages.put_item(
        Item={
            "conversation_id": conversation_id,
            "sort_key": f"{now}#{message_id}",
            "message_id": message_id,
            "role": "user",
            "content": message,
            "user_id": user_id,
        }
    )

    job_id = str(uuid.uuid4())

    execution = _sfn.start_execution(
        stateMachineArn=STATE_MACHINE_ARN,
        name=job_id,  # one execution per job; also a natural dedupe key
        input=json.dumps({"job_id": job_id, "brief": message}),
    )

    # One execution per job for its whole lifetime (revisions loop within
    # the same execution, they don't start new ones), so storing the ARN
    # once here is enough to support stopping the job later.
    _jobs.put_item(
        Item={
            "job_id": job_id,
            "conversation_id": conversation_id,
            "user_id": user_id,
            "brief": message,
            "status": "queued",
            "human_review_rounds": 0,
            "execution_arn": execution["executionArn"],
            "created_at": now,
            "updated_at": now,
        }
    )

    return _response(201, {"conversation_id": conversation_id, "job_id": job_id, "status": "queued"})
