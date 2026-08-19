"""pipeline_task_reviewer — Step Functions Task (waitForTaskToken pattern).

Invoked via the `lambda:invoke.waitForTaskToken` integration: the state
machine execution pauses here until something external calls
SendTaskSuccess/SendTaskFailure with this token — that "something external"
is review_handler (see lambdas/review_handler), triggered by a human
approving/rejecting the draft through the frontend.

This lambda's only job is to persist that token (and the draft it's waiting
on) onto the content_jobs item so review_handler can find it later by
job_id, then return — the actual pause/resume is Step Functions' own
mechanism, not something this code manages.
"""

import os
from datetime import datetime, timezone

import boto3

AWS_REGION = os.environ.get("AWS_REGION", "us-east-1")
CONTENT_JOBS_TABLE = os.environ["CONTENT_JOBS_TABLE"]

_dynamodb = boto3.resource("dynamodb", region_name=AWS_REGION)
_jobs_table = _dynamodb.Table(CONTENT_JOBS_TABLE)


def _now() -> str:
    return datetime.now(timezone.utc).isoformat()


def handler(event: dict, _context) -> None:
    job_id = event["job_id"]
    task_token = event["task_token"]

    _jobs_table.update_item(
        Key={"job_id": job_id},
        UpdateExpression=(
            "SET review_task_token = :token, #status = :status, updated_at = :updated_at"
        ),
        ExpressionAttributeNames={"#status": "status"},
        ExpressionAttributeValues={
            ":token": task_token,
            ":status": "pending_human_review",
            ":updated_at": _now(),
        },
    )
    # No return value — the state machine stays paused until review_handler
    # calls SendTaskSuccess/SendTaskFailure with this token.
