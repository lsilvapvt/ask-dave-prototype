#!/usr/bin/env bash
# Post-deploy smoke test: checks the deployed stack behaves as intended. Needs the
# AWS CLI, curl and python3. Grows with each iteration.
# It writes a few sample objects under history/ and asks the LLM one short question
# (a fraction of a cent); everything it creates is removed on exit.
set -uo pipefail

cd "$(dirname "$0")/../infra" || exit 1

failures=0
pass() { echo "  ok    $1"; }
fail() { echo "  FAIL  $1"; failures=$((failures + 1)); }
check() { local name=$1; shift; if "$@" >/dev/null 2>&1; then pass "$name"; else fail "$name"; fi; }
absent() { ! "$@"; }  # for checks that must NOT match

out() { terraform output -raw "$1"; }
region=$(out aws_region) || { echo "No deployed stack found (terraform output failed)." >&2; exit 1; }
bucket=$(out data_bucket_name)
secret_arn=$(out llm_api_key_secret_arn)
api=$(out api_url)
app=$(out app_url)
frontend_bucket=$(out frontend_bucket_name)

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

echo "Frontend (CloudFront):"
echo "  $app"
code=$(curl -s -o /dev/null -w '%{http_code}' "$app/")
check "app URL returns 200 (got $code)" test "$code" = 200
check "index.html served byte-for-byte unmodified" test \
  "$(curl -s "$app/" | shasum -a 256 | cut -d' ' -f1)" = "$(shasum -a 256 < ../frontend/index.html | cut -d' ' -f1)"
check "config.js points at the live API" grep -qF "\"$api\"" <<<"$(curl -s "$app/config.js")"
code=$(curl -s -o /dev/null -w '%{http_code}' "http://${app#https://}/")
check "plain HTTP redirects to HTTPS (got $code)" test "$code" = 301
headers=$(curl -sI "$app/")
check "HSTS security header present" grep -qi '^strict-transport-security:' <<<"$headers"
check "index.html is not cached stale (no-cache)" grep -qi '^cache-control: no-cache' <<<"$headers"
code=$(curl -s -o /dev/null -w '%{http_code}' "https://${frontend_bucket}.s3.${region}.amazonaws.com/index.html")
check "bucket not readable directly, only via CloudFront (HTTP $code)" test "$code" = 403

echo "API (GET /history):"
echo "  $api"
samples=()
chat_prefixes=()
cleanup() {
  for key in "${samples[@]}"; do aws s3 rm "s3://$bucket/$key" --region "$region" >/dev/null 2>&1; done
  for prefix in "${chat_prefixes[@]}"; do
    for key in $(aws s3api list-objects-v2 --bucket "$bucket" --prefix "$prefix" --region "$region" \
        --query 'Contents[].Key' --output text 2>/dev/null); do
      [[ "$key" == None ]] || aws s3 rm "s3://$bucket/$key" --region "$region" >/dev/null 2>&1
    done
  done
}
trap cleanup EXIT

# json_check '<python expression on b>' : evaluates against the JSON on stdin.
json_check() { python3 -c "import json,sys; b=json.load(sys.stdin); sys.exit(0 if ($1) else 1)"; }

body=$(curl -s -w '\n%{http_code}' "$api/history")
code=${body##*$'\n'}; body=${body%$'\n'*}
check "returns 200 (got $code)" test "$code" = 200
check "body is a JSON list" json_check 'isinstance(b, list)' <<<"$body"

# Out-of-order samples dated 2099 so they sort to the top, plus one corrupt object.
for ts in 2099-01-02T00:00:00.000000Z 2099-01-03T00:00:00.000000Z 2099-01-01T00:00:00.000000Z; do
  key="history/${ts}_smoke-test.json"
  samples+=("$key")
  printf '{"prompt":"smoke %s","response":"ok","timestamp":"%s"}' "$ts" "$ts" |
    aws s3 cp - "s3://$bucket/$key" --region "$region" --content-type application/json >/dev/null
done
corrupt="history/2099-01-04T00:00:00.000000Z_smoke-test.json"
samples+=("$corrupt")
printf '{not json' | aws s3 cp - "s3://$bucket/$corrupt" --region "$region" >/dev/null

body=$(curl -s "$api/history")
check "samples come back newest first" json_check \
  '[i["timestamp"][:10] for i in b[:3]] == ["2099-01-03", "2099-01-02", "2099-01-01"]' <<<"$body"
check "corrupt object skipped, not fatal" json_check 'all(set(i) == {"prompt","response","timestamp"} for i in b)' <<<"$body"
check "whole list is newest first" json_check '[i["timestamp"] for i in b] == sorted((i["timestamp"] for i in b), reverse=True)' <<<"$body"

preflight() {
  curl -s -o /dev/null -D - -X OPTIONS "$api/chat" -H "Origin: $1" \
    -H "Access-Control-Request-Method: POST" -H "Access-Control-Request-Headers: content-type"
}
check "CORS preflight allows the app's own origin" grep -qi "^access-control-allow-origin: $app" <<<"$(preflight "$app")"
check "CORS refuses other websites' origins" absent grep -qi '^access-control-allow-origin:' <<<"$(preflight https://example.com)"
code=$(curl -s -o /dev/null -w '%{http_code}' "$api/no-such-route")
check "unknown route returns 404 (got $code)" test "$code" = 404

# Proves each function's least-privilege role can write to its Terraform-managed log group.
echo "API (POST /chat):"
post() { curl -s -w '\n%{http_code}' -X POST "$api/chat" -H 'Content-Type: application/json' -d "$1"; }
for bad in 'not json' '{}' '{"prompt": "   "}'; do
  code=$(post "$bad"); code=${code##*$'\n'}
  check "rejects $bad with 400 (got $code)" test "$code" = 400
done

body=$(post '{"prompt": "Reply with the single word: pong"}')
code=${body##*$'\n'}; body=${body%$'\n'*}
check "live LLM answer returns 200 (got $code)" test "$code" = 200
if [[ "$code" == 200 ]]; then
  ts=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["timestamp"])' <<<"$body")
  chat_prefixes+=("history/${ts}_")
  answer=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["response"][:60])' <<<"$body")
  echo "        model said: $answer"
  check "answer has the contract fields" json_check \
    'set(b) == {"prompt","response","timestamp"} and b["response"].strip()' <<<"$body"
  check "answer mentions pong" json_check '"pong" in b["response"].lower()' <<<"$body"
  history=$(curl -s "$api/history")
  check "new answer appears in GET /history" python3 -c \
    "import json,sys; b=json.loads(sys.argv[1]); sys.exit(0 if any(i['timestamp']=='$ts' for i in b) else 1)" "$history"
else
  echo "        (A 500 here usually means the LLM key is invalid or has no credits; check the chat function's logs.)"
fi

for fn in history chat; do
  log_group="/aws/lambda/${bucket%-data}-$fn"
  streams=0
  for _ in 1 2 3 4 5 6; do
    streams=$(aws logs describe-log-streams --log-group-name "$log_group" --region "$region" \
      --query 'length(logStreams)' --output text 2>/dev/null || echo 0)
    [[ "$streams" -gt 0 ]] && break
    sleep 5
  done
  check "function logs reach $log_group" test "$streams" -gt 0
done

echo
if ((failures)); then echo "$failures check(s) failed."; exit 1; fi
echo "All smoke checks passed."
