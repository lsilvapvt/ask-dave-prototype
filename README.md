# AskDave

> **Status: prototype in progress.** See `TODO.md` for what's implemented so far. Sections marked TODO are filled in as the build progresses.

AskDave is a small AI chat tool: ask a question, get an answer from an LLM, and browse the history of previous questions and answers. It has a static frontend and a serverless backend, all deployed to AWS with Terraform in one command. See `docs/requirements.md` for what it must do and `docs/architecture-decisions.md` for the reasoning behind every design choice below.

## Prerequisites

- **Terraform 1.11 or newer.** On macOS: `brew install hashicorp/tap/terraform`.
- **AWS credentials** for an IAM identity allowed to create the stack's resources, available through the standard credential chain (`aws configure`, `AWS_PROFILE`, or SSO). Avoid root user access keys.
- **AWS CLI and curl** (optional), used only by the smoke test and the post-destroy leftover check.
- **An Anthropic API key** with credits, from platform.claude.com. Export it as `TF_VAR_llm_api_key`, or run the deploy script interactively and paste it when asked. To avoid saving it in your shell history:

  ```bash
  read -rs TF_VAR_llm_api_key && export TF_VAR_llm_api_key
  ```

The key goes straight to AWS Secrets Manager. It is never written to the repo, to Terraform state or plan files, or to a Lambda environment variable.

The region defaults to `us-east-1`. Override it with `export TF_VAR_aws_region=<region>`.

The model defaults to Claude Haiku 4.5, the fastest and cheapest current Claude model (roughly a quarter of a cent per typical question). For stronger answers at higher cost, set `export TF_VAR_llm_model=claude-sonnet-5-5` or `claude-opus-5-5` before deploying.

## Deploy

```bash
./scripts/deploy.sh
```

To check the deployed stack afterwards (it adds a few sample history entries, asks the model one short question for a fraction of a cent, and removes everything it created):

```bash
./scripts/smoke-test.sh
```

To change the LLM key later, export the new key and bump its version so Terraform pushes it:

```bash
export TF_VAR_llm_api_key_version=2
./scripts/deploy.sh
```

## Destroy

```bash
./scripts/destroy.sh
```

Destroy doesn't need the LLM key. It leaves nothing behind: S3 buckets use `force_destroy`, and the secret is deleted immediately rather than scheduled for deletion. Afterwards the script runs `scripts/verify-destroyed.sh`, which looks for any AWS resource still tagged for this project and fails if one remains. CloudFront teardown takes a few extra minutes; that's expected, not a hang.

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
