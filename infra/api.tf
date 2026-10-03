# HTTP API (API Gateway v2): cheaper and simpler than a REST API for two routes.

resource "aws_apigatewayv2_api" "http" {
  name          = local.name
  protocol_type = "HTTP"
  description   = "${var.project_name} backend API"

  # The page is served from another origin (CloudFront), and POST /chat sends
  # Content-Type: application/json, which triggers a CORS preflight. Only the app's
  # own CloudFront origin is allowed, so other websites can't call the API from a
  # visitor's browser.
  cors_configuration {
    allow_origins = ["https://${aws_cloudfront_distribution.frontend.domain_name}"]
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

  # Rate limiting: a token bucket per route, shared by all callers. Requests over
  # the limit get 429 before reaching Lambda, so they cost nothing and never count
  # as errors. POST /chat is stricter because every call is a paid LLM request.
  default_route_settings {
    throttling_rate_limit  = var.api_rate_limit
    throttling_burst_limit = var.api_burst_limit
  }

  route_settings {
    route_key              = aws_apigatewayv2_route.chat.route_key
    throttling_rate_limit  = var.chat_rate_limit
    throttling_burst_limit = var.chat_burst_limit
  }

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

# POST /chat

resource "aws_apigatewayv2_integration" "chat" {
  api_id                 = aws_apigatewayv2_api.http.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.chat.invoke_arn
  payload_format_version = "2.0"
  timeout_milliseconds   = 30000 # the HTTP API maximum; the function itself stops at 28 s
}

resource "aws_apigatewayv2_route" "chat" {
  #checkov:skip=CKV_AWS_309:The app is public by design; rate limiting comes with API throttling.
  api_id    = aws_apigatewayv2_api.http.id
  route_key = "POST /chat"
  target    = "integrations/${aws_apigatewayv2_integration.chat.id}"
}

resource "aws_lambda_permission" "chat" {
  statement_id  = "AllowApiGatewayPostChat"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.chat.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.http.execution_arn}/*/POST/chat"
}
