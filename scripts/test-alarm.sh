#!/usr/bin/env bash
# Proves the error alarm works end to end: injects one real error into the deployed
# chat function and waits for its CloudWatch alarm to fire (usually 1-3 minutes,
# because Lambda metrics arrive with a delay). If alarm_email is set, an email
# follows. The alarm returns to OK by itself several minutes after the error.
#
# The fault: a direct invocation whose body is a number, a shape API Gateway never
# sends. The handler's JSON parsing raises an unhandled TypeError, which Lambda counts
# as an error. Nothing is written, and the LLM is not called.
set -euo pipefail

cd "$(dirname "$0")/../infra" || exit 1

region=$(terraform output -raw aws_region)
bucket=$(terraform output -raw data_bucket_name)
function="${bucket%-data}-chat"
alarm="$function-errors"
payload_file=$(mktemp)
trap 'rm -f "$payload_file"' EXIT

echo "Injecting one error into $function..."
aws lambda invoke --function-name "$function" --region "$region" \
  --cli-binary-format raw-in-base64-out --payload '{"body": 123}' "$payload_file" \
  --query 'FunctionError' --output text
echo "Function response: $(head -c 200 "$payload_file")"

echo "Waiting for alarm $alarm (up to 5 minutes)..."
for _ in $(seq 1 30); do
  state=$(aws cloudwatch describe-alarms --alarm-names "$alarm" --region "$region" \
    --query 'MetricAlarms[0].StateValue' --output text)
  if [[ "$state" == ALARM ]]; then
    echo "Alarm fired: $alarm is in ALARM."
    aws cloudwatch describe-alarms --alarm-names "$alarm" --region "$region" \
      --query 'MetricAlarms[0].StateReason' --output text
    exit 0
  fi
  sleep 10
done
echo "Alarm $alarm did not fire within 5 minutes (last state: $state)." >&2
exit 1
