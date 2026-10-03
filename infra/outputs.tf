# app_url arrives with the CloudFront iteration; scripts/deploy.sh prints it when present.

output "aws_region" {
  description = "Region the stack is deployed in. Used by the verification scripts."
  value       = var.aws_region
}

output "data_bucket_name" {
  description = "S3 bucket holding the question and answer history."
  value       = aws_s3_bucket.data.bucket
}

output "llm_api_key_secret_arn" {
  description = "ARN of the Secrets Manager secret holding the LLM API key. The ARN is not sensitive; the value is never output."
  value       = aws_secretsmanager_secret.llm_api_key.arn
}

output "api_url" {
  description = "Base URL of the HTTP API. The frontend's config.js points here."
  value       = aws_apigatewayv2_api.http.api_endpoint
}
