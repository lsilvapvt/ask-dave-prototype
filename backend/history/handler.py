"""GET /history Lambda handler.

TODO (see TODO.md "Core build"):
- List objects under the history/ prefix in the data bucket (S3 ListObjectsV2).
- Sort keys descending (the ISO-8601-prefixed key naming makes this a plain lexicographic
  sort — newest first, no extra metadata store needed at this scale).
- Cap at a reasonable number of most-recent items (e.g. 50) and fetch each with GetObject.
- Return the list as the API response body, newest first, matching the frontend's
  expected shape: [{"prompt", "response", "timestamp"}, ...].

IAM for this function should only ever need:
  - s3:ListBucket (scoped to the history/ prefix) and s3:GetObject on the data bucket.
  No Secrets Manager access — this function never touches the LLM key.
"""


def handler(event, context):
    raise NotImplementedError("history handler not yet implemented")
