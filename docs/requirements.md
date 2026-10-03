# AskDave requirements

AskDave is a small AI chat tool: a static web page where a user asks a question, gets an answer from an LLM, and sees the history of previous questions and answers. This prototype defines the backend and infrastructure behind the provided page, deployable into any AWS account.

## Functional behavior

When a prompt is submitted, the backend:

- Calls an LLM.
- Saves `{prompt, response, timestamp}` to S3.
- Returns the answer to the page.

The page also loads and shows previous prompts and answers from S3.

## API contract

The frontend expects exactly this:

- `POST /chat` with `{"prompt": "..."}` returns `{"prompt", "response", "timestamp"}`.
- `GET /history` returns a JSON list of the same objects, **newest first**.
- The page reads the API base URL from a `config.js` file next to `index.html`.

`frontend/index.html` is a fixed, provided asset. It is never edited; only `config.js` is generated at deploy time.

## Deployment and operations

- **Infrastructure as code only.** Every AWS resource is created by Terraform. One command deploys, one destroys, and destroy leaves nothing behind.
- **Portable.** It deploys into any AWS account with that account's credentials and its own LLM API key. Nothing is hardcoded: no account IDs, keys, or names that only work on one machine.
- **Works immediately.** Served over HTTPS and usable right after deploy, with no manual steps. The app URL prints at the end of the deploy command.
- **Least-privilege IAM.** Each backend component can touch only what it needs.
- **Secret handling.** The LLM API key lives in Secrets Manager, never in the repo or a plain environment variable.
- **Observability.** The backend logs to CloudWatch, and an alarm triggers on errors.
- **Near-zero idle cost.** The architecture scales to zero.

## Documentation

The README covers:

- Prerequisites, and how to deploy and destroy.
- A simple architecture diagram.
- The decisions made and why.
- What would break first at 1,000 users, and what to change.
- What to do next with another week.

## Guiding principle

Working and simple beats complete and late. Optional extras come only after the core works: CI via GitHub Actions, remote Terraform state, and rate limiting or basic auth.
