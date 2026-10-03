"""Unit tests for backend/history/handler.py, including the frontend API contract."""

import json

import pytest
from botocore.exceptions import ClientError
from conftest import FakeS3, load_handler


def entry(ts: str, prompt: str = "q", response: str = "a") -> bytes:
    return json.dumps({"prompt": prompt, "response": response, "timestamp": ts}).encode()


@pytest.fixture
def history(monkeypatch):
    module = load_handler("history")
    monkeypatch.setenv("DATA_BUCKET", "test-bucket")
    fake = FakeS3()
    monkeypatch.setattr(module, "s3", fake)
    return module, fake


def call(module):
    result = module.handler({}, None)
    return result["statusCode"], result["headers"], json.loads(result["body"])


def test_empty_bucket_returns_empty_list(history):
    module, _ = history
    status, headers, body = call(module)
    assert status == 200
    assert body == []
    assert headers["Content-Type"] == "application/json"


def test_contract_is_a_bare_list_newest_first_across_pages(history):
    module, fake = history
    stamps = ["2026-10-01T09:00:00.000000Z", "2026-10-03T08:00:00.000000Z",
              "2026-10-02T10:00:00.000000Z", "2026-10-03T09:30:00.000000Z",
              "2026-09-30T23:59:59.999999Z"]  # fmt: skip
    for i, ts in enumerate(stamps):
        fake.objects[f"history/{ts}_{i}.json"] = entry(ts, prompt=f"q{i}")

    status, _, body = call(module)

    assert status == 200
    assert isinstance(body, list)  # the page renders the body directly as the list
    assert [i["timestamp"] for i in body] == sorted(stamps, reverse=True)
    assert all(set(i) == {"prompt", "response", "timestamp"} for i in body)


def test_returns_at_most_limit_newest_items(history, monkeypatch):
    module, fake = history
    monkeypatch.setattr(module, "LIMIT", 3)
    for day in range(1, 10):
        ts = f"2026-10-0{day}T00:00:00.000000Z"
        fake.objects[f"history/{ts}_x.json"] = entry(ts)

    _, _, body = call(module)

    assert [i["timestamp"][:10] for i in body] == ["2026-10-09", "2026-10-08", "2026-10-07"]
    assert len(fake.get_calls) == 3  # never reads objects beyond the limit


def test_skips_unusable_objects_but_returns_the_rest(history):
    module, fake = history
    good = "2026-10-01T00:00:00.000000Z"
    fake.objects.update({
        f"history/{good}_ok.json": entry(good),
        "history/2026-10-02T00:00:00.000000Z_badjson.json": b"{not json",
        "history/2026-10-03T00:00:00.000000Z_badutf8.json": b"\xff\xfe",
        "history/2026-10-04T00:00:00.000000Z_list.json": b"[1, 2]",
        "history/2026-10-05T00:00:00.000000Z_missing.json": b'{"prompt": "q"}',
        "history/2026-10-06T00:00:00.000000Z_nonstr.json":
            b'{"prompt": 1, "response": "a", "timestamp": "t"}',
    })  # fmt: skip

    _, _, body = call(module)

    assert [i["timestamp"] for i in body] == [good]


def test_skips_object_deleted_between_listing_and_read(history, monkeypatch):
    module, fake = history
    ts = "2026-10-01T00:00:00.000000Z"
    fake.objects[f"history/{ts}_ok.json"] = entry(ts)
    fake.objects["history/2026-10-02T00:00:00.000000Z_gone.json"] = entry("t")
    real_get = fake.get_object

    def get_after_delete(Bucket, Key):  # noqa: N803
        fake.objects.pop("history/2026-10-02T00:00:00.000000Z_gone.json", None)
        return real_get(Bucket, Key)

    monkeypatch.setattr(fake, "get_object", get_after_delete)
    _, _, body = call(module)
    assert [i["timestamp"] for i in body] == [ts]


def test_ignores_keys_outside_prefix_or_not_json(history):
    module, fake = history
    fake.objects["other/2026-10-01T00:00:00.000000Z_x.json"] = entry("other")
    fake.objects["history/2026-10-01T00:00:00.000000Z_x.txt"] = entry("txt")
    _, _, body = call(module)
    assert body == []


def test_strips_fields_outside_the_contract(history):
    module, fake = history
    stored = {"prompt": "q", "response": "a", "timestamp": "t", "internal": "secret"}
    fake.objects["history/2026-10-01T00:00:00.000000Z_x.json"] = json.dumps(stored).encode()
    _, _, body = call(module)
    assert body == [{"prompt": "q", "response": "a", "timestamp": "t"}]


def test_listing_failure_raises_so_lambda_counts_an_error(history):
    # Unhandled, the error increments the Lambda Errors metric the alarm watches,
    # and API Gateway answers 500.
    module, fake = history
    fake.list_error = ClientError({"Error": {"Code": "AccessDenied"}}, "ListObjectsV2")
    with pytest.raises(ClientError):
        module.handler({}, None)
