"""Self-test for the tiny HCL block matcher, so the Terraform guards can't pass
silently because the helper stopped finding blocks."""

from repo_files import blocks

SAMPLE = """
resource "aws_s3_bucket" "data" {
  bucket        = "x"
  force_destroy = true
  tags = { a = "b" }
}

resource "aws_s3_bucket" "site" {
  bucket = "y"
}

variable "llm_api_key" {
  type      = string
  sensitive = true
}
"""


def test_finds_resources_by_type():
    found = blocks(SAMPLE, "resource", "aws_s3_bucket")
    assert set(found) == {"data", "site"}
    assert "force_destroy = true" in found["data"]
    assert "force_destroy" not in found["site"]


def test_nested_braces_stay_inside_their_block():
    assert 'tags = { a = "b" }' in blocks(SAMPLE, "resource", "aws_s3_bucket")["data"]


def test_finds_variables():
    assert "sensitive = true" in blocks(SAMPLE, "variable")["llm_api_key"]
