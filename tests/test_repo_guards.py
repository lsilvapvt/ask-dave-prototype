"""Repo-wide guards for the project's hard constraints (see CLAUDE.md)."""

import hashlib
import re

from repo_files import REPO, repo_files, text_files

# sha256 of the provided frontend/index.html. It is a fixed asset and must not be edited.
INDEX_HTML_SHA256 = "375b79d19c55a9be913c8e51e2ec3b0a08f5a8cb75ed990507e68936c8a02f2a"

# This file necessarily contains the patterns it searches for.
SELF = {"tests/test_repo_guards.py"}

SECRET_PATTERNS = {
    "Anthropic API key": re.compile(r"sk-ant-[A-Za-z0-9_-]{20,}"),
    "OpenAI API key": re.compile(r"\bsk-(?:proj-)?[A-Za-z0-9_-]{32,}"),
    "AWS access key id": re.compile(r"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b"),
    "AWS secret key assignment": re.compile(r"aws_secret_access_key\s*[=:]\s*\S{20,}", re.I),
}


def _rel(path):
    return path.relative_to(REPO).as_posix()


def test_index_html_is_unmodified():
    digest = hashlib.sha256((REPO / "frontend/index.html").read_bytes()).hexdigest()
    assert digest == INDEX_HTML_SHA256, (
        "frontend/index.html is a fixed asset and must not be edited"
    )


def test_rendered_config_js_is_not_committed():
    # config.js is rendered by Terraform at deploy time from config.js.tmpl.
    assert "frontend/config.js" not in {_rel(p) for p in repo_files()}


def test_no_tfvars_files_committed():
    offenders = [_rel(p) for p in repo_files() if p.name.endswith(".tfvars")]
    assert not offenders, f"tfvars files may hold the LLM key; never commit them: {offenders}"


def test_no_aws_account_ids():
    # The provider lock file is full of hex hashes that can contain long digit runs.
    pattern = re.compile(r"(?<![\w.])\d{12}(?![\w.])")
    offenders = [
        f"{_rel(p)}: {m.group()}"
        for p in text_files(exclude=SELF | {"infra/.terraform.lock.hcl"})
        for m in pattern.finditer(p.read_text(errors="ignore"))
    ]
    assert not offenders, f"Possible hardcoded AWS account IDs: {offenders}"


def test_no_literal_arns_in_code():
    # ARNs must come from resource attributes or data sources, never literals.
    pattern = re.compile(r"arn:aws[a-z-]*:")
    code = [p for p in text_files(exclude=SELF) if p.suffix in {".tf", ".py", ".sh", ".tmpl"}]
    offenders = [_rel(p) for p in code if pattern.search(p.read_text(errors="ignore"))]
    assert not offenders, f"Literal ARNs found: {offenders}"


def test_no_secrets_committed():
    offenders = [
        f"{_rel(p)}: {label}"
        for p in text_files(exclude=SELF)
        for label, pattern in SECRET_PATTERNS.items()
        if pattern.search(p.read_text(errors="ignore"))
    ]
    assert not offenders, f"Possible secrets in the repo: {offenders}"
