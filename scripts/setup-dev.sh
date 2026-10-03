#!/usr/bin/env bash
# One-time local setup for running scripts/check.sh. Not needed to deploy.
# Creates two virtualenvs: checkov pins library versions that clash with the tests.
set -euo pipefail

cd "$(dirname "$0")/.."

python3 -m venv .venv
.venv/bin/pip install -q --upgrade pip
.venv/bin/pip install -q -r requirements-dev.txt

python3 -m venv .venv-checkov
.venv-checkov/bin/pip install -q --upgrade pip
.venv-checkov/bin/pip install -q -r requirements-checkov.txt

echo "Python tools installed in .venv and .venv-checkov."

missing=()
for tool in terraform tflint shellcheck gitleaks; do
  command -v "$tool" >/dev/null || missing+=("$tool")
done
if ((${#missing[@]})); then
  echo
  echo "Still missing: ${missing[*]}"
  echo "On macOS:"
  echo "  brew install hashicorp/tap/terraform tflint shellcheck gitleaks"
fi
