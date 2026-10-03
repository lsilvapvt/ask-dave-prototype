#!/usr/bin/env bash
# One-command destroy. Should leave nothing behind (S3 buckets use force_destroy).
# Note: CloudFront distribution teardown takes several minutes — this is expected.
set -euo pipefail

cd "$(dirname "$0")/../infra"

terraform destroy -auto-approve
