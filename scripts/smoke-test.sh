#!/usr/bin/env bash
# Post-deploy smoke test: checks the deployed stack behaves as intended. Read-only
# except where noted. Needs the AWS CLI and curl. Grows with each iteration.
set -uo pipefail

cd "$(dirname "$0")/../infra" || exit 1

failures=0
pass() { echo "  ok    $1"; }
fail() { echo "  FAIL  $1"; failures=$((failures + 1)); }
check() { local name=$1; shift; if "$@" >/dev/null 2>&1; then pass "$name"; else fail "$name"; fi; }

out() { terraform output -raw "$1"; }
region=$(out aws_region) || { echo "No deployed stack found (terraform output failed)." >&2; exit 1; }
bucket=$(out data_bucket_name)
secret_arn=$(out llm_api_key_secret_arn)

echo "Data bucket: $bucket"
check "bucket exists" aws s3api head-bucket --bucket "$bucket" --region "$region"
check "all four public access blocks on" test "$(aws s3api get-public-access-block --bucket "$bucket" --region "$region" \
  --query 'PublicAccessBlockConfiguration.[BlockPublicAcls,IgnorePublicAcls,BlockPublicPolicy,RestrictPublicBuckets]' --output text)" = "True	True	True	True"
check "default encryption enabled" aws s3api get-bucket-encryption --bucket "$bucket" --region "$region"
check "bucket policy present" aws s3api get-bucket-policy --bucket "$bucket" --region "$region"
code=$(curl -s -o /dev/null -w '%{http_code}' "https://${bucket}.s3.${region}.amazonaws.com/")
check "anonymous listing refused (HTTP $code)" test "$code" = 403

echo "LLM key secret:"
# shellcheck disable=SC2016 # backticks are a JMESPath literal, not shell substitution
check "secret exists with a current value" test "$(aws secretsmanager describe-secret --secret-id "$secret_arn" --region "$region" \
  --query 'length(VersionIdsToStages.*[] | [?@ == `AWSCURRENT`])' --output text)" = 1
if [[ -n "${TF_VAR_llm_api_key:-}" ]]; then
  # The key is ephemeral and write-only: it must never appear in Terraform state.
  if terraform state pull | grep -qF -- "$TF_VAR_llm_api_key"; then
    fail "key absent from Terraform state"
  else
    pass "key absent from Terraform state"
  fi
else
  echo "  skip  key absent from Terraform state (TF_VAR_llm_api_key not set)"
fi

echo
if ((failures)); then echo "$failures check(s) failed."; exit 1; fi
echo "All smoke checks passed."
