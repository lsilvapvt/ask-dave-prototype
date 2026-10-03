"""POST /chat Lambda handler.

TODO (see TODO.md "Core build"):
- Parse {"prompt": "..."} from the API Gateway HTTP API proxy event body.
- Fetch the LLM API key from Secrets Manager (ARN passed via env var — never the key itself).
- Call the LLM's REST API directly via urllib.request (no SDK, no layer, keeps the
  deploy artifact dependency-free — see docs/architecture-decisions.md).
- Write {"prompt", "response", "timestamp"} as a JSON object to S3 under
  history/<ISO-8601-timestamp>_<uuid>.json (per-item storage, not a shared file —
  avoids a read-modify-write race; see docs/architecture-decisions.md).
- Return {"prompt", "response", "timestamp"} as the API response body.

IAM for this function should only ever need:
  - secretsmanager:GetSecretValue on the one LLM-key secret ARN
  - s3:PutObject on the data bucket's history/ prefix
"""


def handler(event, context):
    raise NotImplementedError("chat handler not yet implemented")
