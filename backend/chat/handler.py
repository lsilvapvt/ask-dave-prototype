"""POST /chat: asks the LLM, saves the question and answer to S3, returns them.

Request body: {"prompt": "..."}. Response body: {"prompt", "response", "timestamp"}.

The LLM is the Anthropic Messages API, called over HTTPS with the standard library
(urllib), so the deployment zip has no dependencies. boto3 comes with the Lambda
runtime.

The API key is read from Secrets Manager at runtime; the environment holds only the
secret's ARN. Each question and answer is saved as its own object,
history/<UTC timestamp>_<uuid>.json, so concurrent requests never overwrite each other
and the history endpoint can sort newest first by key alone.

IAM: secretsmanager:GetSecretValue on the one LLM key secret, s3:PutObject on
history/* only. It cannot read or list history.
"""

import base64
import json
import logging
import os
import time
import urllib.error
import urllib.request
import uuid
from datetime import UTC, datetime

import boto3

ANTHROPIC_URL = "https://api.anthropic.com/v1/messages"
ANTHROPIC_VERSION = "2023-06-01"
MODEL = os.environ.get("LLM_MODEL", "claude-haiku-4-5")
MAX_TOKENS = int(os.environ.get("LLM_MAX_TOKENS", "1024"))
MAX_PROMPT_CHARS = int(os.environ.get("MAX_PROMPT_CHARS", "4000"))
SYSTEM_PROMPT = (
    "You are Dave, a helpful assistant. Answer clearly and concisely. "
    "Write plain text without Markdown formatting, because answers are displayed as plain text."
)

# Transient Anthropic statuses worth one retry (529 means the API is overloaded).
RETRYABLE_STATUSES = {408, 429, 500, 502, 503, 504, 529}
RETRY_DELAY_SECONDS = 1.0
# Time kept back for saving to S3 and returning before the Lambda deadline.
DEADLINE_RESERVE_SECONDS = 3.0
SECRET_CACHE_SECONDS = 300
FALLBACK_ANSWER = "Sorry, I couldn't produce an answer to that. Please try rephrasing it."

logger = logging.getLogger()
logger.setLevel(logging.INFO)

# Created once per Lambda container and reused across invocations.
s3 = boto3.client("s3")
secrets = boto3.client("secretsmanager")

_key_cache: dict = {"value": None, "expires": 0.0}


class BadRequest(Exception):
    """The caller sent an unusable request; answered with HTTP 400."""


class LLMError(Exception):
    """The LLM call failed. Propagates, so Lambda counts it as an error."""


def response(status: int, body: dict) -> dict:
    return {
        "statusCode": status,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(body),
    }


def parse_prompt(event: dict) -> str:
    body = event.get("body") or ""
    try:
        if event.get("isBase64Encoded"):
            body = base64.b64decode(body, validate=True).decode("utf-8", errors="replace")
        payload = json.loads(body)
    except ValueError:  # covers invalid base64 (binascii.Error) and invalid JSON
        raise BadRequest('Request body must be JSON like {"prompt": "..."}.') from None

    prompt = payload.get("prompt") if isinstance(payload, dict) else None
    if not isinstance(prompt, str) or not prompt.strip():
        raise BadRequest('"prompt" must be a non-empty string.')
    prompt = prompt.strip()
    if len(prompt) > MAX_PROMPT_CHARS:
        raise BadRequest(f'"prompt" must be at most {MAX_PROMPT_CHARS} characters.')
    return prompt


def get_api_key() -> str:
    """Fetch the key from Secrets Manager, cached briefly so most requests skip the call.

    The short cache means a rotated key takes effect within a few minutes.
    """
    now = time.monotonic()
    if _key_cache["value"] is None or now >= _key_cache["expires"]:
        secret = secrets.get_secret_value(SecretId=os.environ["LLM_API_KEY_SECRET_ARN"])
        _key_cache["value"] = secret["SecretString"].strip()
        _key_cache["expires"] = now + SECRET_CACHE_SECONDS
    return _key_cache["value"]


def call_llm(prompt: str, deadline: float) -> str:
    """Ask the model and return its text answer. One retry on transient failures."""
    request = urllib.request.Request(
        ANTHROPIC_URL,
        method="POST",
        headers={
            "content-type": "application/json",
            "x-api-key": get_api_key(),
            "anthropic-version": ANTHROPIC_VERSION,
        },
        data=json.dumps({
            "model": MODEL,
            "max_tokens": MAX_TOKENS,
            "system": SYSTEM_PROMPT,
            "messages": [{"role": "user", "content": prompt}],
        }).encode(),
    )  # fmt: skip

    for attempt in (1, 2):
        timeout = deadline - time.monotonic() - DEADLINE_RESERVE_SECONDS
        if timeout < 1:
            raise LLMError("No time left to call the LLM before the Lambda deadline")
        try:
            # Fixed https:// URL above, so the scheme is never attacker-controlled.
            with urllib.request.urlopen(request, timeout=timeout) as resp:  # noqa: S310
                return extract_text(json.load(resp))
        except urllib.error.HTTPError as err:
            # The error body never contains the key; it is truncated to keep logs small.
            detail = err.read(500).decode("utf-8", errors="replace")
            if err.code in RETRYABLE_STATUSES and attempt == 1:
                logger.warning("Anthropic API returned HTTP %s, retrying once", err.code)
                time.sleep(RETRY_DELAY_SECONDS)
                continue
            raise LLMError(f"Anthropic API returned HTTP {err.code}: {detail}") from None
        except (urllib.error.URLError, TimeoutError) as err:
            if attempt == 1:
                logger.warning("Anthropic API unreachable (%s), retrying once", err)
                continue
            raise LLMError(f"Anthropic API unreachable: {err}") from None
    raise AssertionError("unreachable")


def extract_text(message: dict) -> str:
    text = "".join(
        block.get("text", "") for block in message.get("content", []) if block.get("type") == "text"
    ).strip()
    stop_reason = message.get("stop_reason")
    if stop_reason == "max_tokens":
        logger.info("Answer hit the %d-token limit and was cut short", MAX_TOKENS)
    if not text:
        logger.warning("Model returned no text (stop_reason=%s)", stop_reason)
        return FALLBACK_ANSWER
    return text


def utc_timestamp() -> str:
    # Fixed-width UTC with milliseconds, e.g. 2026-10-03T17:19:15.209Z: browsers parse
    # it reliably, and keys built from it sort chronologically.
    return datetime.now(UTC).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def save(item: dict) -> str:
    key = f"history/{item['timestamp']}_{uuid.uuid4().hex}.json"
    s3.put_object(
        Bucket=os.environ["DATA_BUCKET"],
        Key=key,
        Body=json.dumps(item).encode(),
        ContentType="application/json",
    )
    return key


def handler(event, context):
    try:
        prompt = parse_prompt(event)
    except BadRequest as err:
        return response(400, {"error": str(err)})

    remaining = context.get_remaining_time_in_millis() / 1000 if context else 28.0
    deadline = time.monotonic() + remaining

    answer = call_llm(prompt, deadline)
    item = {"prompt": prompt, "response": answer, "timestamp": utc_timestamp()}
    key = save(item)

    logger.info("Saved %s (%d prompt chars, %d answer chars)", key, len(prompt), len(answer))
    return response(200, item)
