"""GET /history: returns saved questions and answers, newest first.

Each question and answer is one S3 object under history/, named
history/<UTC ISO-8601 timestamp>_<uuid>.json. Because the timestamp leads the key,
sorting keys in reverse order sorts entries newest first with no extra index.

Dependencies: the standard library plus boto3, which the Lambda runtime provides.

IAM: s3:ListBucket on the history/ prefix and s3:GetObject on history/* only.
No Secrets Manager access; this function never touches the LLM key.
"""

import json
import logging
import os
from concurrent.futures import ThreadPoolExecutor

import boto3
from botocore.exceptions import ClientError

PREFIX = "history/"
FIELDS = ("prompt", "response", "timestamp")
LIMIT = int(os.environ.get("HISTORY_LIMIT", "50"))
MAX_PARALLEL_READS = 16

logger = logging.getLogger()
logger.setLevel(logging.INFO)

# Created once per Lambda container and reused across invocations.
s3 = boto3.client("s3")


def list_recent_keys(bucket: str, limit: int) -> list[str]:
    """Return up to `limit` history keys, newest first.

    S3 lists keys in ascending order only, so this reads every key under the prefix.
    That is fine at prototype scale; see docs/architecture-decisions.md for what
    replaces it at 1,000 users.
    """
    keys: list[str] = []
    for page in s3.get_paginator("list_objects_v2").paginate(Bucket=bucket, Prefix=PREFIX):
        keys.extend(obj["Key"] for obj in page.get("Contents", []) if obj["Key"].endswith(".json"))
    keys.sort(reverse=True)
    return keys[:limit]


def fetch_item(bucket: str, key: str) -> dict | None:
    """Read one history object. Returns None, and logs why, if it is unusable."""
    try:
        item = json.loads(s3.get_object(Bucket=bucket, Key=key)["Body"].read())
    except ClientError as err:
        # For example, deleted between the listing and the read.
        logger.warning("Skipping %s: %s", key, err.response["Error"].get("Code"))
        return None
    except ValueError:  # covers invalid JSON and invalid UTF-8
        logger.warning("Skipping %s: not valid JSON", key)
        return None

    if not isinstance(item, dict) or not all(isinstance(item.get(f), str) for f in FIELDS):
        logger.warning("Skipping %s: missing or non-string fields", key)
        return None
    # Return exactly the contract fields, nothing else that may be stored.
    return {f: item[f] for f in FIELDS}


def response(status: int, body) -> dict:
    return {
        "statusCode": status,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(body),
    }


def handler(event, context):
    bucket = os.environ["DATA_BUCKET"]

    # A listing failure is not caught: Lambda logs the traceback, counts it in the
    # Errors metric that the CloudWatch alarm watches, and API Gateway returns 500.
    keys = list_recent_keys(bucket, LIMIT)

    if not keys:
        return response(200, [])

    # Reads are I/O-bound, so threads fetch them in parallel. map() keeps key order,
    # which keeps the result newest first.
    with ThreadPoolExecutor(max_workers=min(MAX_PARALLEL_READS, len(keys))) as pool:
        items = [item for item in pool.map(lambda k: fetch_item(bucket, k), keys) if item]

    logger.info("Returning %d of %d history items", len(items), len(keys))
    return response(200, items)
