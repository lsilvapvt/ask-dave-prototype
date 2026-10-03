#!/usr/bin/env bash
# One-command deploy. Supply the Anthropic API key through the environment:
#   read -rs TF_VAR_llm_api_key && export TF_VAR_llm_api_key
#   ./scripts/deploy.sh
# Run it interactively without the variable set and it asks for the key instead.
# Optional settings are TF_VAR_* variables; see README "Configuration".
set -euo pipefail

cd "$(dirname "$0")/../infra" || exit 1

# Prerequisites
command -v terraform >/dev/null || { echo "Terraform is not installed (see README prerequisites)." >&2; exit 1; }
tf_version=$(terraform version -json | python3 -c 'import json,sys; print(json.load(sys.stdin)["terraform_version"])' 2>/dev/null ||
  terraform version | head -1 | sed -E 's/[^0-9]*([0-9.]+).*/\1/')
if [[ "$(printf '%s\n' 1.11.0 "$tf_version" | sort -V | head -1)" != 1.11.0 ]]; then
  echo "Terraform $tf_version found; 1.11 or newer is required." >&2
  exit 1
fi

if [[ -z "${TF_VAR_llm_api_key:-}" ]]; then
  if [[ -t 0 ]]; then
    read -rsp "Anthropic API key (input hidden): " TF_VAR_llm_api_key
    echo
    export TF_VAR_llm_api_key
  else
    echo "TF_VAR_llm_api_key is not set. Export your Anthropic API key before deploying." >&2
    exit 1
  fi
fi

terraform init -input=false >/dev/null
echo "Terraform $tf_version initialized."

# Show where this is about to deploy, so a wrong profile or region is caught early.
region=$(echo 'var.aws_region' | terraform console | tr -d '"')
if command -v aws >/dev/null; then
  if identity=$(aws sts get-caller-identity --query Arn --output text 2>/dev/null); then
    echo "Deploying as $identity in $region."
    [[ "$identity" == *":root" ]] && echo "Warning: these are root user credentials; an IAM user or role is safer." >&2
  else
    echo "AWS credentials not found or not valid (see README prerequisites)." >&2
    exit 1
  fi
else
  echo "Deploying to $region."
fi

echo "A first deploy takes about 3-5 minutes, mostly CloudFront publishing the site."
terraform apply -auto-approve -input=false

app_url=$(terraform output -raw app_url 2>/dev/null) || { echo "Deployed, but no app_url output was found." >&2; exit 1; }
alarm_topic=$(terraform output -raw alarm_topic_arn 2>/dev/null || true)

cat <<SUMMARY

Deployed.
  App:     $app_url
  API:     $(terraform output -raw api_url)
  Model:   $(echo 'var.llm_model' | terraform console | tr -d '"')
  Alarms:  $(terraform output -json alarm_names | python3 -c 'import json,sys; print(", ".join(json.load(sys.stdin)))')
           ${alarm_topic:+email notifications on (confirm the subscription email from AWS)}${alarm_topic:-no email notifications (set TF_VAR_alarm_email to add them)}

Next: open the app URL, run ./scripts/smoke-test.sh to verify, and ./scripts/destroy.sh to remove everything.

App URL: $app_url
SUMMARY
