#!/usr/bin/env bash
# Proves `terraform destroy` left nothing behind: finds every resource still tagged
# for this project and confirms each one is really gone. The tagging API can list
# deleted resources for a while, so each hit is double-checked with its own service.
# Note: another copy of this stack in the same account and region would also match.
set -euo pipefail

cd "$(dirname "$0")/../infra" || exit 1

export TF_VAR_llm_api_key="${TF_VAR_llm_api_key:-unused}"
tfvar() { echo "var.$1" | terraform console | tr -d '"'; }
project=$(tfvar project_name)
region=$(tfvar aws_region)

echo "Checking for leftover resources tagged Project=$project in $region..."
arns=$(aws resourcegroupstaggingapi get-resources --region "$region" \
  --tag-filters "Key=Project,Values=$project" "Key=ManagedBy,Values=terraform" \
  --query 'ResourceTagMappingList[].ResourceARN' --output text)

leftovers=0
for arn in $arns; do
  case "$arn" in
    arn:*:s3:::*)
      if aws s3api head-bucket --bucket "${arn##*:::}" >/dev/null 2>&1; then
        echo "  LEFT  $arn"; leftovers=$((leftovers + 1))
      fi ;;
    arn:*:secretsmanager:*)
      deleted=$(aws secretsmanager describe-secret --secret-id "$arn" --region "$region" \
        --query 'DeletedDate' --output text 2>/dev/null || echo gone)
      if [[ "$deleted" == "None" ]]; then
        echo "  LEFT  $arn"; leftovers=$((leftovers + 1))
      fi ;;
    *)
      echo "  LEFT  $arn (no specific check; verify manually)"; leftovers=$((leftovers + 1)) ;;
  esac
done

if ((leftovers)); then
  echo "$leftovers resource(s) left behind."
  exit 1
fi
echo "Nothing left behind."
