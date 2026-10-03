"""Shared helpers for the static guard tests. Everything here reads files only."""

import re
import subprocess
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
INFRA = REPO / "infra"

BINARY_SUFFIXES = {".pdf", ".png", ".jpg", ".jpeg", ".gif", ".ico", ".zip"}


def repo_files() -> list[Path]:
    """Files git tracks or would track: committed plus untracked-but-not-ignored.

    Using git's view keeps .venv, .terraform, state files and other ignored local
    artifacts out of the scans, both on a laptop and in CI.
    """
    out = subprocess.run(  # noqa: S603 - fixed argv, no user input
        ["git", "ls-files", "--cached", "--others", "--exclude-standard"],  # noqa: S607
        cwd=REPO,
        check=True,
        capture_output=True,
        text=True,
    ).stdout
    return [REPO / line for line in out.splitlines() if (REPO / line).is_file()]


def text_files(exclude: set[str] = frozenset()) -> list[Path]:
    return [
        p
        for p in repo_files()
        if p.suffix.lower() not in BINARY_SUFFIXES and p.relative_to(REPO).as_posix() not in exclude
    ]


def terraform_source() -> str:
    return "\n".join(p.read_text() for p in sorted(INFRA.glob("*.tf")))


_BLOCK_HEADER = re.compile(r'^(resource|data|variable)\s+"([^"]+)"(?:\s+"([^"]+)")?\s*\{', re.M)


def blocks(source: str, kind: str, type_: str | None = None) -> dict[str, str]:
    """Return {name: body} for top-level HCL blocks such as resource "aws_s3_bucket" "x".

    A deliberately small brace matcher, not a full HCL parser. It is good enough for
    the structural guards in this repo and is itself covered by test_hcl_helper.py.
    For variable blocks the single label is the name and type_ is ignored.
    """
    found: dict[str, str] = {}
    for m in _BLOCK_HEADER.finditer(source):
        if m.group(1) != kind:
            continue
        if kind == "variable":
            name = m.group(2)
        else:
            if type_ is not None and m.group(2) != type_:
                continue
            name = m.group(3) if type_ is not None else f"{m.group(2)}.{m.group(3)}"
        depth, i = 1, m.end()
        while depth and i < len(source):
            depth += {"{": 1, "}": -1}.get(source[i], 0)
            i += 1
        found[name] = source[m.end() : i - 1]
    return found
