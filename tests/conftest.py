"""Shared fixtures. Handler tests never touch AWS: S3 is replaced by FakeS3."""

import importlib.util
import io
import os

import pytest
from botocore.exceptions import ClientError
from repo_files import REPO

# boto3.client() at import time needs a region; no credentials are ever used.
os.environ.setdefault("AWS_DEFAULT_REGION", "us-east-1")


def load_handler(name: str):
    """Import backend/<name>/handler.py under a unique module name.

    Both Lambdas name their module handler.py, so a plain import would collide.
    """
    spec = importlib.util.spec_from_file_location(
        f"{name}_handler", REPO / "backend" / name / "handler.py"
    )
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class FakeS3:
    """In-memory stand-in for the few S3 client calls the handlers make."""

    def __init__(self, objects: dict[str, bytes] | None = None, page_size: int = 2):
        self.objects = dict(objects or {})
        self.page_size = page_size
        self.list_error: ClientError | None = None
        self.get_calls: list[str] = []

    # list_objects_v2 paginator: ascending key order, page_size keys per page.
    def get_paginator(self, operation: str):
        assert operation == "list_objects_v2"
        return self

    def paginate(self, Bucket: str, Prefix: str):  # noqa: N803 - boto3's parameter names
        if self.list_error:
            raise self.list_error
        keys = sorted(k for k in self.objects if k.startswith(Prefix))
        if not keys:
            yield {"KeyCount": 0}  # S3 omits "Contents" entirely when empty
        for i in range(0, len(keys), self.page_size):
            yield {"Contents": [{"Key": k} for k in keys[i : i + self.page_size]]}

    def get_object(self, Bucket: str, Key: str):  # noqa: N803
        self.get_calls.append(Key)
        if Key not in self.objects:
            raise ClientError({"Error": {"Code": "NoSuchKey"}}, "GetObject")
        return {"Body": io.BytesIO(self.objects[Key])}

    def put_object(self, Bucket: str, Key: str, Body, **kwargs):  # noqa: N803
        self.objects[Key] = Body if isinstance(Body, bytes) else Body.encode()
        return {}


@pytest.fixture
def fake_s3():
    return FakeS3()
