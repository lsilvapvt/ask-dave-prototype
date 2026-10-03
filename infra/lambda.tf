# Lambda functions. Each is a single stdlib-only file zipped by Terraform itself:
# no pip install, no layer, no build step outside `terraform apply`.

data "archive_file" "history" {
  type        = "zip"
  source_file = "${path.module}/../backend/history/handler.py"
  output_path = "${path.module}/.build/history.zip"
}

# Created by Terraform before the function, so Lambda never auto-creates one that
# would survive `terraform destroy`.
resource "aws_cloudwatch_log_group" "history" {
  #checkov:skip=CKV_AWS_158:Logs hold no secrets; a customer-managed KMS key costs about $1/month idle.
  #checkov:skip=CKV_AWS_338:One-year retention is a compliance default; 14 days keeps idle cost near zero (configurable).
  name              = "/aws/lambda/${local.name}-history"
  retention_in_days = var.log_retention_days
}

resource "aws_lambda_function" "history" {
  #checkov:skip=CKV_AWS_50:X-Ray tracing is out of scope for the prototype; CloudWatch logs and alarms cover observability.
  #checkov:skip=CKV_AWS_115:Reserved concurrency fails to deploy in new accounts with a low concurrency quota; API throttling limits load instead.
  #checkov:skip=CKV_AWS_116:Invoked synchronously by API Gateway, so a dead-letter queue would never receive anything.
  #checkov:skip=CKV_AWS_117:Uses only public AWS endpoints; a VPC would need NAT or endpoints that cost money idle.
  #checkov:skip=CKV_AWS_173:Environment variables hold only a bucket name and a limit, nothing secret.
  #checkov:skip=CKV_AWS_272:Code signing needs a signing profile and pipeline; out of scope for the prototype.
  function_name = "${local.name}-history"
  description   = "GET /history: returns saved questions and answers, newest first."
  role          = aws_iam_role.history.arn

  filename         = data.archive_file.history.output_path
  source_code_hash = data.archive_file.history.output_base64sha256
  handler          = "handler.handler"
  runtime          = local.lambda_runtime
  architectures    = [local.lambda_architecture]
  memory_size      = 256
  timeout          = 10

  environment {
    variables = {
      DATA_BUCKET   = aws_s3_bucket.data.bucket
      HISTORY_LIMIT = tostring(var.history_limit)
    }
  }

  logging_config {
    log_format = "Text"
    log_group  = aws_cloudwatch_log_group.history.name
  }

  # The role's permissions must exist before the first invocation can log or read.
  depends_on = [aws_iam_role_policy.history]
}

data "archive_file" "chat" {
  type        = "zip"
  source_file = "${path.module}/../backend/chat/handler.py"
  output_path = "${path.module}/.build/chat.zip"
}

resource "aws_cloudwatch_log_group" "chat" {
  #checkov:skip=CKV_AWS_158:Logs hold no secrets; a customer-managed KMS key costs about $1/month idle.
  #checkov:skip=CKV_AWS_338:One-year retention is a compliance default; 14 days keeps idle cost near zero (configurable).
  name              = "/aws/lambda/${local.name}-chat"
  retention_in_days = var.log_retention_days
}

resource "aws_lambda_function" "chat" {
  #checkov:skip=CKV_AWS_50:X-Ray tracing is out of scope for the prototype; CloudWatch logs and alarms cover observability.
  #checkov:skip=CKV_AWS_115:Reserved concurrency fails to deploy in new accounts with a low concurrency quota; API throttling limits load instead.
  #checkov:skip=CKV_AWS_116:Invoked synchronously by API Gateway, so a dead-letter queue would never receive anything.
  #checkov:skip=CKV_AWS_117:Calls the public Anthropic API; a VPC would need a NAT gateway that costs money idle.
  #checkov:skip=CKV_AWS_173:Environment variables hold only names, limits and the secret's ARN; the key itself stays in Secrets Manager.
  #checkov:skip=CKV_AWS_272:Code signing needs a signing profile and pipeline; out of scope for the prototype.
  function_name = "${local.name}-chat"
  description   = "POST /chat: asks the LLM, saves the question and answer, returns them."
  role          = aws_iam_role.chat.arn

  filename         = data.archive_file.chat.output_path
  source_code_hash = data.archive_file.chat.output_base64sha256
  handler          = "handler.handler"
  runtime          = local.lambda_runtime
  architectures    = [local.lambda_architecture]
  memory_size      = 256
  # Just under API Gateway's 30-second integration limit. The handler budgets its
  # LLM call against the remaining time, keeping a few seconds to save and respond.
  timeout = 28

  environment {
    variables = {
      DATA_BUCKET            = aws_s3_bucket.data.bucket
      LLM_API_KEY_SECRET_ARN = aws_secretsmanager_secret.llm_api_key.arn # the ARN, never the key
      LLM_MODEL              = var.llm_model
      LLM_MAX_TOKENS         = tostring(var.llm_max_tokens)
      MAX_PROMPT_CHARS       = tostring(var.max_prompt_chars)
    }
  }

  logging_config {
    log_format = "Text"
    log_group  = aws_cloudwatch_log_group.chat.name
  }

  depends_on = [aws_iam_role_policy.chat, aws_secretsmanager_secret_version.llm_api_key]
}
