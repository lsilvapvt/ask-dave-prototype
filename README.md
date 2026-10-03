# AskDave

> **Status: prototype in progress.** See `TODO.md` for what's implemented so far. Sections marked TODO are filled in as the build progresses.

AskDave is a small AI chat tool: ask a question, get an answer from an LLM, and browse the history of previous questions and answers. It has a static frontend and a serverless backend, all deployed to AWS with Terraform in one command. See `docs/requirements.md` for what it must do and `docs/architecture-decisions.md` for the reasoning behind every design choice below.

## Prerequisites

_TODO: AWS CLI configured with credentials, Terraform version, how to supply the LLM API key._

## Deploy

```bash
./scripts/deploy.sh
```

_TODO: confirm this is the complete, true one-command deploy once implemented._

## Destroy

```bash
./scripts/destroy.sh
```

Destroy is designed to leave nothing behind (S3 buckets use `force_destroy`). CloudFront teardown takes a few extra minutes — that's expected, not a hang.

## Architecture

_TODO: diagram + short written walkthrough._

## Decisions and why

See `docs/architecture-decisions.md` for the full writeup. Summary once finalized goes here.

## What would break first at 1,000 users

_TODO — draft already in `docs/architecture-decisions.md`._

## What I'd do next with another week

_TODO — draft already in `docs/architecture-decisions.md`._

## Static checks and CI

Every push and pull request runs `.github/workflows/ci.yml`. It needs no AWS credentials and deploys nothing. The same checks run locally:

```bash
./scripts/setup-dev.sh   # once: Python tools into .venv and .venv-checkov
./scripts/check.sh       # terraform fmt/validate, tflint, ruff, pytest, checkov, gitleaks, shellcheck
```

`setup-dev.sh` lists any missing CLI tools. On macOS: `brew install hashicorp/tap/terraform tflint shellcheck gitleaks`.

The pytest suite includes guard tests for the project's hard constraints: `index.html` is unmodified, no account IDs, literal ARNs, keys or tfvars are committed, and everything Terraform creates can be fully destroyed (S3 `force_destroy`, Secrets Manager recovery window of 0, Terraform-managed Lambda log groups, no wildcard IAM resources).
