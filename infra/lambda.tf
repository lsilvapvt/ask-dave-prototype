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
