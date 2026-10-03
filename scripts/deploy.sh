#!/usr/bin/env bash
# One-command deploy. Supply the LLM API key through the environment:
#   export TF_VAR_llm_api_key=...      (or run interactively and paste it when asked)
#   ./scripts/deploy.sh
set -euo pipefail

cd "$(dirname "$0")/../infra" || exit 1

command -v terraform >/dev/null || { echo "terraform is not installed (see README prerequisites)." >&2; exit 1; }

if [[ -z "${TF_VAR_llm_api_key:-}" ]]; then
  if [[ -t 0 ]]; then
    read -rsp "LLM API key (input hidden): " TF_VAR_llm_api_key
    echo
    export TF_VAR_llm_api_key
  else
    echo "TF_VAR_llm_api_key is not set. Export it before deploying." >&2
    exit 1
  fi
fi

terraform init -input=false
echo "Deploying. A first deploy takes about 5 minutes while CloudFront publishes the site."
terraform apply -auto-approve -input=false

echo
if app_url=$(terraform output -raw app_url 2>/dev/null); then
  echo "App URL: $app_url"
else
  echo "Deployed, but no app_url output was found." >&2
  exit 1
fi
