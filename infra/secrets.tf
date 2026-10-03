# LLM API key. Lambdas receive only this secret's ARN and fetch the value at runtime.

resource "aws_secretsmanager_secret" "llm_api_key" {
  #checkov:skip=CKV_AWS_149:The AWS-managed key encrypts at rest; a customer-managed KMS key costs about $1/month even when idle.
  #checkov:skip=CKV2_AWS_57:A third-party LLM provider key cannot be rotated by a Lambda; rotate it at the provider and redeploy.
  name        = "${local.name}/llm-api-key"
  description = "LLM provider API key for ${var.project_name}."

  # Delete immediately on destroy. The default 7-30 day recovery window leaves the
  # secret "pending deletion", which survives destroy and blocks reusing its name.
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "llm_api_key" {
  secret_id = aws_secretsmanager_secret.llm_api_key.id

  # Write-only: sent to AWS but never stored in Terraform state or plan files.
  secret_string_wo         = var.llm_api_key
  secret_string_wo_version = var.llm_api_key_version
}
