# askdave-prototype

## What this is

The prototype of **AskDave**, a small AI chat tool on AWS: a static page where users ask questions, get LLM answers, and browse the history of previous questions and answers. Everything is deployed through infrastructure as code, so anyone can clone the repo and run it cold in their own AWS account with zero manual steps.

**Requirements:** `docs/requirements.md`.

**Architecture rationale:** `docs/architecture-decisions.md`. Read it before changing any major design choice. It records *why* each decision was made, not just what it is, and the README draws on the same reasoning.

## How to work in this repo

Someone deploying this follows only the README, in an account this repo has never seen. Optimize for:

- **Working on the first try.** No manual post-deploy steps, nothing tied to one developer's machine, account, or region.
- **Clarity of decisions.** The README explains *why*, not just *what*.
- **Minimal idle cost.** The architecture must scale to zero.
- **Least-privilege IAM, secret handling, and observability** as first-class requirements, not nice-to-haves.
- **Simplicity over completeness.** Working and simple beats complete and late. Get the core loop solid before any optional extras.

## Architecture summary

(Full rationale in `docs/architecture-decisions.md`.)

- **IaC:** Terraform. One command to apply, one to destroy. Region, account, and globally unique names are all parameterized or generated.
- **Backend:** two small Python Lambda functions, `chat` and `history`, each with its **own** least-privilege IAM role, behind a single **API Gateway HTTP API**.
- **LLM:** a third-party LLM API (Anthropic or OpenAI) called with Python's stdlib `urllib.request`: no SDK, no Lambda layer, no packaging step. The bring-your-own API key lives in **Secrets Manager**; the Lambda environment holds only the **secret's ARN**, never the key.
- **Storage:** S3, **one JSON object per Q&A** (key pattern `history/<ISO-8601-timestamp>_<uuid>.json`), deliberately not a single shared file, to avoid a read-modify-write race. Lexicographic key order gives newest-first for free.
- **Frontend:** the provided `frontend/index.html` is served **unmodified** from a private S3 bucket behind **CloudFront** with Origin Access Control. That gives HTTPS on a `*.cloudfront.net` domain with no certificate or DNS setup.
- **`config.js`** is rendered by Terraform (`templatefile()`) with the live API Gateway URL and uploaded as an `aws_s3_object` during `apply`, so the app works right after deploy.
- **Observability:** Lambda logs to Terraform-managed CloudWatch log groups; a CloudWatch alarm watches the Lambda `Errors` metric.
- **Deploy/destroy:** `scripts/deploy.sh` and `scripts/destroy.sh` wrap `terraform apply/destroy -auto-approve`. `deploy.sh` prints the app URL at the end. CloudFront teardown takes several minutes; that is expected, not a hang.

## Repo layout

```
askdave-prototype/
├── CLAUDE.md                          # this file
├── README.md                          # user-facing docs: deploy, destroy, architecture, decisions
├── TODO.md                            # iteration plan and implementation checklist
├── docs/
│   ├── requirements.md                # what AskDave must do
│   └── architecture-decisions.md      # rationale behind every design choice
├── frontend/
│   ├── index.html                     # PROVIDED, DO NOT EDIT
│   └── config.js.tmpl                 # Terraform templatefile() source; rendered config.js is never committed
├── backend/
│   ├── chat/handler.py                # POST /chat: calls the LLM, writes to S3, returns {prompt, response, timestamp}
│   └── history/handler.py             # GET /history: lists and returns S3 objects, newest first
├── infra/                             # Terraform, one file per concern: main.tf (naming), storage.tf, secrets.tf, iam.tf, lambda.tf, api.tf, cloudfront.tf
├── scripts/
│   ├── deploy.sh / destroy.sh
│   ├── smoke-test.sh                  # post-deploy checks against the live stack
│   ├── verify-destroyed.sh            # post-destroy leftover check (run by destroy.sh)
│   ├── setup-dev.sh                   # local dev tooling (venvs)
│   └── check.sh                       # local run of the CI static checks
├── tests/                             # pytest: guard tests (constraints, destroy rules, least privilege) + handler unit tests
└── .github/workflows/ci.yml           # static checks only, no AWS credentials
```

## Hard constraints — do not violate these

1. **Never edit `frontend/index.html`.** It is a fixed, provided asset (a guard test checks its hash). Only `config.js` is generated at deploy time.
2. **No hardcoded AWS account IDs, resource names, or ARNs anywhere.** It must deploy cleanly into a *different* AWS account, with *different* credentials and a *different* LLM API key. Use `data "aws_caller_identity"`, `random_id`/`random_pet` for globally unique names, and input variables with safe defaults for everything else.
3. **The LLM API key must never appear** in the repo, in a plain Lambda environment variable, or anywhere outside Secrets Manager. It is supplied at deploy time via `TF_VAR_llm_api_key`, as an `ephemeral` variable feeding the write-only `secret_string_wo`, so it never reaches Terraform state either.
4. **Every AWS resource comes from Terraform, and `terraform destroy` must leave nothing behind.** S3 buckets need `force_destroy`, secrets need `recovery_window_in_days = 0`, and Lambda log groups must be Terraform-managed.
5. **Keep the Lambda dependency footprint at zero** (stdlib, plus the boto3 the Lambda runtime already provides). No build step, layer, or Docker packaging.

## Current status / next steps

See `TODO.md` for the iteration plan and current progress.
