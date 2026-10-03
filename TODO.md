# Roadmap

What comes after v1.0, roughly in priority order. The reasoning behind each item is in [docs/architecture-decisions.md](docs/architecture-decisions.md), under "What breaks first at 1,000 users" and "What to do with another week".

## Scaling

- [ ] **Raise Lambda concurrency.** New AWS accounts often allow only 10 concurrent Lambda executions, and the API answers 503 beyond that. Request an increase through Service Quotas (1,000 is the usual default), then raise the API throttle limits to match.
- [ ] **Per-user rate limits.** Today's throttle is shared by all callers. Per-user limits need user identity (see basic authentication below) or an AWS WAF rate-based rule per IP.
- [ ] **Queue LLM requests.** An SQS queue in front of the LLM call, so bursts above Anthropic's per-minute limits wait instead of failing.
- [ ] **DynamoDB for history.** A timestamp sort key gives paginated newest-first queries, instead of listing every S3 key on each page load.
- [ ] **Streaming or async answers**, so long answers from larger models never hit API Gateway's 30-second limit, and the page can show text as it arrives.

## Features

- [ ] **Conversation memory per browser session.** Route `/chat` and `/history` through CloudFront so requests are same-origin, set a session cookie, store entries under `history/<session-id>/`, and send each session's last ~10 exchanges to the model as context.
- [ ] **Basic authentication for the page and the API.** A CloudFront Function checks credentials at the edge; it reuses the same-origin routing above, plus a secret origin header so the direct API Gateway URL can't bypass the login.
- [ ] **More LLM providers.** An `llm_provider` variable (`anthropic` or `openai`), per-provider request and response adapters with unit tests, a required `llm_model` for non-default providers, and an optional base-URL override for compatible gateways.

## Operations

- [ ] **Remote Terraform state and a CI `terraform plan`.** An S3 state backend and an OIDC role for GitHub Actions, in a small separate bootstrap stack, because both must outlive `terraform destroy` of the app.
- [ ] **Test in a second AWS account.** v1.0 was rehearsed from a clean copy of the repo in a different region; a different account would also confirm nothing depends on this account's settings or quotas.
