#!/usr/bin/env python3
"""Idempotently create the Bedrock-KB vector index on an OpenSearch Serverless
collection. Invoked by Terraform's `null_resource.create_vector_index` via
local-exec (see ../opensearch.tf) because index creation is a data-plane
operation with no native `aws` or `awscc` Terraform resource.

Requires only boto3 (already a dependency of the AWS CLI / any Python
environment used to run this Terraform config) — no extra pip installs.
"""
import hashlib
import json
import os
import sys
import urllib.request
import urllib.error

import boto3
from botocore.auth import SigV4Auth
from botocore.awsrequest import AWSRequest

REGION = os.environ["AWS_REGION"]
ENDPOINT = os.environ["COLLECTION_ENDPOINT"]
INDEX_NAME = os.environ["INDEX_NAME"]
VECTOR_FIELD = os.environ["VECTOR_FIELD"]
TEXT_FIELD = os.environ["TEXT_FIELD"]
METADATA_FIELD = os.environ["METADATA_FIELD"]
DIMENSIONS = int(os.environ["DIMENSIONS"])

SERVICE = "aoss"
BASE_URL = ENDPOINT if ENDPOINT.startswith("https://") else f"https://{ENDPOINT}"


def signed_request(method: str, path: str, body: dict | None = None) -> urllib.request.Request:
    session = boto3.Session()
    credentials = session.get_credentials()
    if credentials is None:
        raise RuntimeError("No AWS credentials found in the environment running `terraform apply`.")

    data = json.dumps(body).encode("utf-8") if body is not None else b""
    url = f"{BASE_URL}{path}"

    # X-Amz-Content-SHA256 turns out to be required for AOSS write/mutating
    # calls specifically (PUT to create an index) — read-only calls
    # (GET/HEAD) work fine without it, which is what made this non-obvious:
    # confirmed by a live 403->200 flip when this header was added, with
    # everything else (identity, data-access policy, network policy)
    # unchanged.
    headers = {
        "Content-Type": "application/json",
        "X-Amz-Content-SHA256": hashlib.sha256(data).hexdigest(),
    }
    aws_request = AWSRequest(method=method, url=url, data=data, headers=headers)
    SigV4Auth(credentials, SERVICE, REGION).add_auth(aws_request)

    req = urllib.request.Request(url, data=data, method=method, headers=dict(aws_request.headers))
    return req


def call(method: str, path: str, body: dict | None = None, ok_statuses=(200,)):
    req = signed_request(method, path, body)
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return resp.status, json.loads(resp.read() or b"{}")
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read() or b"{}")


def main() -> int:
    # Idempotency: skip creation if the index already exists.
    status, _ = call("HEAD", f"/{INDEX_NAME}")
    if status == 200:
        print(f"Index '{INDEX_NAME}' already exists on {ENDPOINT}, skipping creation.")
        return 0

    mapping_body = {
        "settings": {"index.knn": True},
        "mappings": {
            "properties": {
                VECTOR_FIELD: {
                    "type": "knn_vector",
                    "dimension": DIMENSIONS,
                    "method": {
                        "name": "hnsw",
                        "engine": "faiss",
                        "space_type": "l2",
                    },
                },
                TEXT_FIELD: {"type": "text"},
                METADATA_FIELD: {"type": "text", "index": False},
            }
        },
    }

    status, resp = call("PUT", f"/{INDEX_NAME}", mapping_body, ok_statuses=(200, 201))
    if status not in (200, 201):
        print(f"Failed to create index '{INDEX_NAME}': HTTP {status} {resp}", file=sys.stderr)
        return 1

    print(f"Created index '{INDEX_NAME}' on {ENDPOINT}.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
