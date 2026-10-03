# scripts/deploy.sh prints app_url at the end of every deploy.

output "app_url" {
  description = "The app's HTTPS URL. Open it in a browser."
  value       = "https://${aws_cloudfront_distribution.frontend.domain_name}"
}

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

output "frontend_bucket_name" {
  description = "Private S3 bucket holding index.html and config.js."
  value       = aws_s3_bucket.frontend.bucket
}

output "cloudfront_distribution_id" {
  description = "CloudFront distribution serving the frontend."
  value       = aws_cloudfront_distribution.frontend.id
}
