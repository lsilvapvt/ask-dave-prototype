# Implementation checklist

Keep "working and simple" ahead of "complete" — the core loop (deploy → chat → saved to S3 → shows in history → destroy leaves nothing) matters far more than any optional extra.

## Iteration plan

Each iteration deploys a working slice, is verified with a scripted check, then destroyed cleanly before the next one. All AWS resources come from Terraform only; each iteration adds matching CI static checks.

1. [x] Tooling and CI skeleton (nothing deployed): providers, variables, `scripts/check.sh`, `.github/workflows/ci.yml`, guard tests
2. [x] Storage and secret: data bucket, Secrets Manager secret (write-only, `recovery_window_in_days = 0`), default tags, `scripts/smoke-test.sh`, `scripts/verify-destroyed.sh`
3. [x] `history` Lambda + HTTP API `GET /history` (Terraform-managed log groups, scoped IAM, CORS, access logs, handler unit tests)
4. [x] `chat` Lambda + `POST /chat` (Anthropic Messages API, default model `claude-haiku-4-5`; live-tested end to end)
5. [ ] Frontend bucket + CloudFront/OAC + `index.html` and rendered `config.js` (no-cache), CORS narrowed to the CloudFront domain
6. [ ] CloudWatch `Errors` alarms (optional SNS email)
7. [ ] API throttling, deploy-script polish, fresh-account rehearsal, README write-up

## Core build

- [x] `infra/providers.tf` — AWS provider, required Terraform version, local state (remote state deliberately not used, see architecture-decisions.md)
- [x] `infra/variables.tf` — region, project prefix, `llm_api_key` (sensitive, ephemeral, no default), `llm_api_key_version` (model/provider config arrives with the chat iteration)
- [x] S3 history data bucket: `force_destroy`, public access blocked, SSE-S3, ACLs disabled, HTTPS-only policy, `random_id` suffix
- [ ] S3 frontend bucket (CloudFront iteration)
- [x] Secrets Manager secret holding `llm_api_key` (write-only value: never in Terraform state)
- [x] IAM role + policy for `chat` Lambda (`GetSecretValue` on the one secret, `PutObject` on `history/*`, own log group; verified with the IAM policy simulator)
- [x] IAM role + policy for `history` Lambda (`ListBucket` limited to `history/`, `GetObject` on `history/*`, writes only its own log group; verified with the IAM policy simulator)
- [x] `backend/chat/handler.py` — parse `{"prompt"}`, call LLM via `urllib`, write `{prompt, response, timestamp}` to S3, return it
- [x] `backend/history/handler.py` — list + fetch recent S3 objects under `history/`, return newest-first (corrupt objects skipped and logged)
- [x] Lambda function resources (zip via `archive_file` data source — no external deps, no layer)
- [x] API Gateway HTTP API with `POST /chat` and `GET /history` routes, Lambda proxy integrations, CORS enabled
- [ ] CloudFront distribution + Origin Access Control in front of the frontend bucket
- [ ] `frontend/config.js.tmpl` rendered via `templatefile()` with the live API Gateway URL, uploaded as `aws_s3_object` (not committed as a static file — deploy-time generated)
- [ ] Upload `frontend/index.html` to the frontend bucket via Terraform (unmodified — never hand-edit this file)
- [ ] CloudWatch alarm on the `chat`/`history` Lambdas' `Errors` metric
- [ ] `infra/outputs.tf` — `app_url` (CloudFront domain), API Gateway URL (for debugging)
- [x] `scripts/deploy.sh` — prompts for the key if unset, `init` + `apply`, prints `app_url` once it exists
- [x] `scripts/destroy.sh` — destroys without needing the real key, then runs `verify-destroyed.sh`
- [ ] End-to-end test: run `deploy.sh` fresh, confirm chat works and history loads with zero manual steps, then run `destroy.sh` and confirm nothing is left in the AWS account

## README

- [ ] Prerequisites + exact deploy/destroy commands
- [ ] Simple architecture diagram
- [ ] Decisions made and why — pull from `docs/architecture-decisions.md`
- [ ] "What breaks first at 1,000 users" — pull from `docs/architecture-decisions.md`
- [ ] "What I'd do with another week" — pull from `docs/architecture-decisions.md`

## Optional extras (only once the core is solid)

- [x] GitHub Actions CI: `terraform fmt -check`, `validate`, tflint, Checkov, gitleaks, ruff, pytest, shellcheck (no `plan`: it would need AWS credentials via an out-of-stack IAM role)
- [ ] Remote Terraform state (S3 backend + DynamoDB lock table)
- [ ] Basic rate limiting (API Gateway throttling) or simple shared-secret auth header

## Post-v1.0

- [ ] Additional LLM providers: an `llm_provider` variable (`anthropic` | `openai`), per-provider request/response adapters in the `chat` handler with unit tests, a required `llm_model` for non-default providers, and an optional base-URL override for compatible gateways. An endpoint variable alone isn't enough: auth headers, request fields, and response shapes differ per provider.

## Release checklist

- [ ] Fresh clone into a clean directory and re-run `deploy.sh` with a *different* set of test AWS credentials if possible, to catch any accidental hardcoding
- [ ] Double-check no account IDs, ARNs, or personal resource names are hardcoded anywhere
- [ ] Double-check the LLM key never appears in committed files or `terraform.tfvars`
