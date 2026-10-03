#!/usr/bin/env bash
# One-command deploy. Requires var.llm_api_key to be supplied, e.g.:
#   TF_VAR_llm_api_key="sk-..." ./scripts/deploy.sh
set -euo pipefail

cd "$(dirname "$0")/../infra"

terraform init -input=false
terraform apply -auto-approve

echo
echo "App URL:"
terraform output -raw app_url
echo
