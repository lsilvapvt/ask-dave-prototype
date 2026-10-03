#!/usr/bin/env bash
# One-command destroy. Leaves nothing behind (see scripts/verify-destroyed.sh).
# CloudFront teardown takes several minutes; that is expected, not a hang.
set -euo pipefail

cd "$(dirname "$0")/../infra" || exit 1

# Terraform requires every variable without a default to be set, even for destroy,
# but destroy never uses the key's value. A dummy means destroying doesn't need it.
export TF_VAR_llm_api_key="${TF_VAR_llm_api_key:-unused-during-destroy}"

terraform init -input=false
terraform destroy -auto-approve -input=false

if command -v aws >/dev/null; then
  echo
  ../scripts/verify-destroyed.sh
else
  echo "AWS CLI not installed: skipping the leftover-resource check."
fi
