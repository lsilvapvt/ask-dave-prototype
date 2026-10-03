"""Unit tests for backend/chat/handler.py. No network, no AWS: S3, Secrets Manager
and the Anthropic HTTP call are all replaced with fakes."""

import base64
import io
import json
import logging
import re
import urllib.error

import pytest
from conftest import FakeS3, load_handler

FAKE_KEY = (
    "fake-llm-key-for-unit-tests"  # deliberately not key-shaped, so secret scanners stay quiet
)
SECRET_ARN = "secret-arn-placeholder"  # noqa: S105 - not a secret; real ARNs are banned as literals


class FakeSecrets:
    def __init__(self):
        self.calls = 0

    def get_secret_value(self, SecretId):  # noqa: N803 - boto3's parameter name
        assert SecretId == SECRET_ARN
        self.calls += 1
        return {"SecretString": FAKE_KEY + "\n"}  # trailing newline must be stripped


class FakeHTTP:
    """Replaces urllib.request.urlopen. Each queued outcome is a dict (a JSON response)
    or an exception to raise."""

    def __init__(self, *outcomes):
        self.outcomes = list(outcomes)
        self.requests = []

    def __call__(self, request, timeout):
        self.requests.append((request, timeout))
        outcome = self.outcomes.pop(0)
        if isinstance(outcome, Exception):
            raise outcome
        return io.BytesIO(json.dumps(outcome).encode())


def anthropic_message(text="Paris.", stop_reason="end_turn"):
    content = [{"type": "text", "text": text}] if text is not None else []
    return {"type": "message", "role": "assistant", "content": content, "stop_reason": stop_reason}


def http_error(code, body=b'{"type":"error","error":{"type":"x","message":"y"}}'):
    return urllib.error.HTTPError("https://api.anthropic.com", code, "err", {}, io.BytesIO(body))


class Context:
    def __init__(self, remaining_ms=28_000):
        self.remaining_ms = remaining_ms

    def get_remaining_time_in_millis(self):
        return self.remaining_ms


@pytest.fixture
def chat(monkeypatch):
    module = load_handler("chat")
    monkeypatch.setenv("DATA_BUCKET", "test-bucket")
    monkeypatch.setenv("LLM_API_KEY_SECRET_ARN", SECRET_ARN)
    fake_s3, fake_secrets = FakeS3(), FakeSecrets()
    monkeypatch.setattr(module, "s3", fake_s3)
    monkeypatch.setattr(module, "secrets", fake_secrets)
    monkeypatch.setattr(module.time, "sleep", lambda s: None)
    return module, fake_s3, fake_secrets


def use_http(monkeypatch, module, *outcomes):
    fake = FakeHTTP(*outcomes)
    monkeypatch.setattr(module.urllib.request, "urlopen", fake)
    return fake


def post(module, body, context=None, raw=False):
    event = {"body": body if raw else json.dumps(body)}
    result = module.handler(event, context or Context())
    return result["statusCode"], json.loads(result["body"])


# Happy path and the API contract


def test_returns_the_contract_and_saves_one_object(chat, monkeypatch):
    module, fake_s3, _ = chat
    use_http(monkeypatch, module, anthropic_message("Paris."))

    status, body = post(module, {"prompt": "  Capital of France?  "})

    assert status == 200
    assert set(body) == {"prompt", "response", "timestamp"}
    assert body["prompt"] == "Capital of France?"
    assert body["response"] == "Paris."
    assert re.fullmatch(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z", body["timestamp"])
    [(key, stored)] = fake_s3.objects.items()
    assert re.fullmatch(rf"history/{re.escape(body['timestamp'])}_[0-9a-f]{{32}}\.json", key)
    assert json.loads(stored) == body


def test_sends_a_well_formed_anthropic_request(chat, monkeypatch):
    module, _, _ = chat
    http = use_http(monkeypatch, module, anthropic_message())

    post(module, {"prompt": "hi"})

    [(request, timeout)] = http.requests
    assert request.full_url == "https://api.anthropic.com/v1/messages"
    assert request.get_method() == "POST"
    headers = {k.lower(): v for k, v in request.header_items()}
    assert headers["x-api-key"] == FAKE_KEY
    assert headers["anthropic-version"] == "2023-06-01"
    sent = json.loads(request.data)
    assert sent["model"] == "claude-haiku-4-5"
    assert sent["max_tokens"] == 1024
    assert sent["messages"] == [{"role": "user", "content": "hi"}]
    assert sent["system"]
    assert 0 < timeout <= 28


def test_round_trip_chat_then_history_newest_first(chat, monkeypatch):
    module, fake_s3, _ = chat
    use_http(monkeypatch, module, anthropic_message("one"), anthropic_message("two"))
    post(module, {"prompt": "first"})
    post(module, {"prompt": "second"})

    history = load_handler("history")
    monkeypatch.setattr(history, "s3", fake_s3)
    items = json.loads(history.handler({}, None)["body"])

    assert [i["prompt"] for i in items] == ["second", "first"]


def test_accepts_a_base64_encoded_body(chat, monkeypatch):
    module, _, _ = chat
    use_http(monkeypatch, module, anthropic_message())
    encoded = base64.b64encode(json.dumps({"prompt": "hi"}).encode()).decode()
    result = module.handler({"body": encoded, "isBase64Encoded": True}, Context())
    assert result["statusCode"] == 200


# Bad requests: answered with 400, nothing called, nothing saved


@pytest.mark.parametrize(
    "body",
    ["not json", "[]", "{}", '{"prompt": 42}', '{"prompt": "   "}', '{"prompt": null}', ""],
)
def test_rejects_unusable_bodies_with_400(chat, monkeypatch, body):
    module, fake_s3, fake_secrets = chat
    http = use_http(monkeypatch, module)
    status, payload = post(module, body, raw=True)
    assert status == 400
    assert "error" in payload
    assert not http.requests and not fake_s3.objects and fake_secrets.calls == 0


def test_rejects_overlong_prompts(chat, monkeypatch):
    module, fake_s3, _ = chat
    monkeypatch.setattr(module, "MAX_PROMPT_CHARS", 10)
    use_http(monkeypatch, module)
    status, _ = post(module, {"prompt": "x" * 11})
    assert status == 400
    assert not fake_s3.objects


# LLM failures: retried once if transient, otherwise raised so Lambda counts an error


@pytest.mark.parametrize("code", [429, 500, 529])
def test_retries_once_on_transient_errors(chat, monkeypatch, code):
    module, fake_s3, _ = chat
    http = use_http(monkeypatch, module, http_error(code), anthropic_message("ok"))
    status, body = post(module, {"prompt": "hi"})
    assert status == 200 and body["response"] == "ok"
    assert len(http.requests) == 2 and len(fake_s3.objects) == 1


@pytest.mark.parametrize("code", [400, 401, 403, 404])
def test_does_not_retry_permanent_errors_and_saves_nothing(chat, monkeypatch, code):
    module, fake_s3, _ = chat
    http = use_http(monkeypatch, module, http_error(code))
    with pytest.raises(module.LLMError, match=f"HTTP {code}"):
        post(module, {"prompt": "hi"})
    assert len(http.requests) == 1 and not fake_s3.objects


def test_gives_up_after_a_second_transient_failure(chat, monkeypatch):
    module, fake_s3, _ = chat
    use_http(monkeypatch, module, http_error(529), http_error(529))
    with pytest.raises(module.LLMError):
        post(module, {"prompt": "hi"})
    assert not fake_s3.objects


def test_retries_once_on_network_errors(chat, monkeypatch):
    module, _, _ = chat
    use_http(monkeypatch, module, TimeoutError("timed out"), anthropic_message("ok"))
    status, _ = post(module, {"prompt": "hi"})
    assert status == 200


def test_does_not_call_the_llm_without_time_left(chat, monkeypatch):
    module, _, _ = chat
    http = use_http(monkeypatch, module)
    with pytest.raises(module.LLMError, match="No time left"):
        post(module, {"prompt": "hi"}, context=Context(remaining_ms=2_000))
    assert not http.requests


def test_failure_logs_never_contain_the_api_key(chat, monkeypatch, caplog):
    module, _, _ = chat
    use_http(monkeypatch, module, http_error(529), http_error(401))
    with caplog.at_level(logging.DEBUG), pytest.raises(module.LLMError) as err:
        post(module, {"prompt": "hi"})
    assert FAKE_KEY not in caplog.text
    assert FAKE_KEY not in str(err.value)


# Model output edge cases


@pytest.mark.parametrize("text", [None, "", "   "])
def test_empty_or_refused_answers_get_a_friendly_fallback(chat, monkeypatch, text):
    module, fake_s3, _ = chat
    use_http(monkeypatch, module, anthropic_message(text, stop_reason="refusal"))
    status, body = post(module, {"prompt": "hi"})
    assert status == 200
    assert body["response"] == module.FALLBACK_ANSWER
    assert len(fake_s3.objects) == 1


def test_joins_multiple_text_blocks_and_ignores_others(chat, monkeypatch):
    module, _, _ = chat
    message = anthropic_message()
    message["content"] = [
        {"type": "thinking", "thinking": "hidden"},
        {"type": "text", "text": "Hello, "},
        {"type": "text", "text": "world."},
    ]
    use_http(monkeypatch, module, message)
    _, body = post(module, {"prompt": "hi"})
    assert body["response"] == "Hello, world."


# Secret handling


def test_secret_is_cached_between_invocations(chat, monkeypatch):
    module, _, fake_secrets = chat
    use_http(monkeypatch, module, anthropic_message(), anthropic_message())
    post(module, {"prompt": "one"})
    post(module, {"prompt": "two"})
    assert fake_secrets.calls == 1


def test_secret_is_refetched_after_the_cache_expires(chat, monkeypatch):
    module, _, fake_secrets = chat
    use_http(monkeypatch, module, anthropic_message(), anthropic_message())
    post(module, {"prompt": "one"})
    module._key_cache["expires"] = 0.0
    post(module, {"prompt": "two"})
    assert fake_secrets.calls == 2
