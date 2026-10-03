# HTTP API (API Gateway v2): cheaper and simpler than a REST API for two routes.

resource "aws_apigatewayv2_api" "http" {
  name          = local.name
  protocol_type = "HTTP"
  description   = "${var.project_name} backend API"

  # The page is served from another origin (CloudFront), and POST /chat sends
  # Content-Type: application/json, which triggers a CORS preflight. Origins are
  # narrowed to the CloudFront domain once the frontend exists.
  cors_configuration {
    allow_origins = ["*"]
    allow_methods = ["GET", "POST", "OPTIONS"]
    allow_headers = ["content-type"]
    max_age       = 3600
  }
}

resource "aws_cloudwatch_log_group" "api_access" {
  #checkov:skip=CKV_AWS_158:Logs hold no secrets; a customer-managed KMS key costs about $1/month idle.
  #checkov:skip=CKV_AWS_338:One-year retention is a compliance default; 14 days keeps idle cost near zero (configurable).
  name              = "/aws/apigateway/${local.name}"
  retention_in_days = var.log_retention_days
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.http.id
  name        = "$default"
  auto_deploy = true

  # One JSON line per request: who called what, the status, and how long it took.
  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.api_access.arn
    format = jsonencode({
      requestId          = "$context.requestId"
      ip                 = "$context.identity.sourceIp"
      requestTime        = "$context.requestTime"
      routeKey           = "$context.routeKey"
      status             = "$context.status"
      responseLatency    = "$context.responseLatency"
      integrationStatus  = "$context.integrationStatus"
      integrationError   = "$context.integrationErrorMessage"
      integrationLatency = "$context.integrationLatency"
    })
  }
}

# GET /history

resource "aws_apigatewayv2_integration" "history" {
  api_id                 = aws_apigatewayv2_api.http.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.history.invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "history" {
  #checkov:skip=CKV_AWS_309:The app is public by design; rate limiting comes with API throttling.
  api_id    = aws_apigatewayv2_api.http.id
  route_key = "GET /history"
  target    = "integrations/${aws_apigatewayv2_integration.history.id}"
}

# Lets this API invoke the function only through this exact route.
resource "aws_lambda_permission" "history" {
  statement_id  = "AllowApiGatewayGetHistory"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.history.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.http.execution_arn}/*/GET/history"
}
