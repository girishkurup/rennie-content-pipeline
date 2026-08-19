"""pipeline_finalize — Step Functions Task.

Terminal step of the pipeline: marks the job "completed" (human approved) or
"escalated" (human rejected max_human_review_iterations times without
approving — needs manual attention outside the automated pipeline; the
by_status GSI lets a dashboard query for these directly). Mirrors the final
draft to S3 alongside the DynamoDB update, same as pipeline_task_writer does
for earlier stages.
"""

import os
from datetime import datetime, timezone

import boto3

AWS_REGION = os.environ.get("AWS_REGION", "us-east-1")
CONTENT_JOBS_TABLE = os.environ["CONTENT_JOBS_TABLE"]
ARTIFACTS_BUCKET = os.environ["ARTIFACTS_BUCKET"]

_dynamodb = boto3.resource("dynamodb", region_name=AWS_REGION)
_jobs_table = _dynamodb.Table(CONTENT_JOBS_TABLE)
_s3 = boto3.client("s3", region_name=AWS_REGION)


def _now() -> str:
    return datetime.now(timezone.utc).isoformat()


def handler(event: dict, _context) -> dict:
    job_id = event["job_id"]
    draft = event["draft"]
    outcome = event.get("outcome", "completed")  # "completed" | "escalated"

    final_key = f"jobs/{job_id}/final_draft.md"
    _s3.put_object(Bucket=ARTIFACTS_BUCKET, Key=final_key, Body=draft.encode("utf-8"), ContentType="text/markdown")

    _jobs_table.update_item(
        Key={"job_id": job_id},
        UpdateExpression=(
            "SET final_draft = :draft, final_draft_s3_key = :s3_key, #status = :status, "
            "updated_at = :updated_at, completed_at = :completed_at "
            "REMOVE review_task_token"
        ),
        ExpressionAttributeNames={"#status": "status"},
        ExpressionAttributeValues={
            ":draft": draft,
            ":s3_key": final_key,
            ":status": outcome,
            ":updated_at": _now(),
            ":completed_at": _now(),
        },
    )

    return {"job_id": job_id, "status": outcome}
