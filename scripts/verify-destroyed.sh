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
# CloudFront is global and its tags are only visible through us-east-1.
arns=$(for r in $(printf '%s\n' "$region" us-east-1 | sort -u); do
  aws resourcegroupstaggingapi get-resources --region "$r" \
    --tag-filters "Key=Project,Values=$project" "Key=ManagedBy,Values=terraform" \
    --query 'ResourceTagMappingList[].ResourceARN' --output text
done | tr '\t' '\n' | sort -u)

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
    arn:*:lambda:*:function:*)
      if aws lambda get-function --function-name "$arn" --region "$region" >/dev/null 2>&1; then
        echo "  LEFT  $arn"; leftovers=$((leftovers + 1))
      fi ;;
    arn:*:logs:*:log-group:*)
      name=${arn#*:log-group:}; name=${name%:\*}
      if [[ "$(aws logs describe-log-groups --log-group-name-prefix "$name" --region "$region" \
          --query "length(logGroups[?logGroupName=='$name'])" --output text)" != 0 ]]; then
        echo "  LEFT  $arn"; leftovers=$((leftovers + 1))
      fi ;;
    arn:*:apigateway:*::/apis/*)
      if aws apigatewayv2 get-api --api-id "${arn##*/apis/}" --region "$region" >/dev/null 2>&1; then
        echo "  LEFT  $arn"; leftovers=$((leftovers + 1))
      fi ;;
    arn:*:cloudfront::*:distribution/*)
      if aws cloudfront get-distribution --id "${arn##*/}" >/dev/null 2>&1; then
        echo "  LEFT  $arn"; leftovers=$((leftovers + 1))
      fi ;;
    *)
      echo "  LEFT  $arn (no specific check; verify manually)"; leftovers=$((leftovers + 1)) ;;
  esac
done

# Not everything shows up in the tagging API: IAM is global, and a log group that
# Lambda auto-created (the classic leftover) carries no tags. Check those by name.
for role in $(aws iam list-roles --query "Roles[?starts_with(RoleName, '$project-')].RoleName" --output text); do
  echo "  LEFT  IAM role $role"; leftovers=$((leftovers + 1))
done
# CloudFront origin access controls can't be tagged.
for oac in $(aws cloudfront list-origin-access-controls \
    --query "OriginAccessControlList.Items[?starts_with(Name, '$project-')].Name" --output text); do
  [[ "$oac" == None ]] || { echo "  LEFT  CloudFront origin access control $oac"; leftovers=$((leftovers + 1)); }
done
for prefix in "/aws/lambda/$project-" "/aws/apigateway/$project-"; do
  for group in $(aws logs describe-log-groups --log-group-name-prefix "$prefix" --region "$region" \
      --query 'logGroups[].logGroupName' --output text); do
    echo "  LEFT  log group $group"; leftovers=$((leftovers + 1))
  done
done

if ((leftovers)); then
  echo "$leftovers resource(s) left behind."
  exit 1
fi
echo "Nothing left behind."
