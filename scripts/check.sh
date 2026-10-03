#!/usr/bin/env bash
# Runs the same static checks as .github/workflows/ci.yml, locally. Deploys nothing
# and needs no AWS credentials. Run scripts/setup-dev.sh once first.
# Every check runs even if an earlier one fails; the exit code is non-zero if any
# check failed or its tool is missing.
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1
ROOT=$PWD
export PATH="$ROOT/.venv/bin:$ROOT/.venv-checkov/bin:$PATH"

results=()
status=0

run() {
  local name=$1 tool=$2
  shift 2
  if ! command -v "$tool" >/dev/null; then
    results+=("MISSING  $name ($tool not installed; see scripts/setup-dev.sh)")
    status=1
    return
  fi
  echo "==> $name"
  if "$@"; then
    results+=("ok       $name")
  else
    results+=("FAILED   $name")
    status=1
  fi
}

run "terraform fmt"      terraform  terraform -chdir=infra fmt -check -recursive -diff
run "terraform init"     terraform  terraform -chdir=infra init -backend=false -input=false
run "terraform validate" terraform  terraform -chdir=infra validate
run "tflint init"        tflint     tflint --chdir=infra --init
run "tflint"             tflint     tflint --chdir=infra --format compact
run "ruff lint"          ruff       ruff check .
run "ruff format"        ruff       ruff format --check .
run "pytest"             pytest     pytest
run "checkov"            checkov    checkov --config-file .checkov.yaml
run "gitleaks"           gitleaks   gitleaks git --redact .
run "shellcheck"         shellcheck shellcheck scripts/*.sh

echo
echo "Summary:"
printf '  %s\n' "${results[@]}"
exit "$status"
