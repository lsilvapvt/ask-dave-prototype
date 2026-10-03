# Error alarms. Each fires when at least one error happens in a one-minute window,
# typically within 1-3 minutes because metrics arrive with a delay. It returns to OK
# on its own after errors stop; in testing that took several minutes (over 4).
#
# - Lambda Errors, per function: unhandled exceptions, including timeouts. The
#   handlers deliberately let LLM and S3 failures propagate so they land here.
# - API Gateway 5xx: failures the functions never see, such as throttling or a
#   broken invoke permission.
#
# Client mistakes (HTTP 400) are not errors and never trigger an alarm.

locals {
  notify        = var.alarm_email != ""
  alarm_actions = local.notify ? [aws_sns_topic.alarms[0].arn] : []
  alarmed_lambdas = {
    chat    = aws_lambda_function.chat.function_name
    history = aws_lambda_function.history.function_name
  }
}

resource "aws_cloudwatch_metric_alarm" "lambda_errors" {
  for_each = local.alarmed_lambdas

  alarm_name        = "${each.value}-errors"
  alarm_description = "The ${each.key} function raised an error. Check log group /aws/lambda/${each.value}."
  namespace         = "AWS/Lambda"
  metric_name       = "Errors"
  dimensions        = { FunctionName = each.value }

  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = 1
  # No invocations means no data, which is healthy rather than unknown.
  treat_missing_data = "notBreaching"

  alarm_actions = local.alarm_actions
  ok_actions    = local.alarm_actions
}

resource "aws_cloudwatch_metric_alarm" "api_5xx" {
  alarm_name        = "${local.name}-api-5xx"
  alarm_description = "The HTTP API returned a 5xx response. Check log group /aws/apigateway/${local.name}."
  namespace         = "AWS/ApiGateway"
  metric_name       = "5xx"
  dimensions = {
    ApiId = aws_apigatewayv2_api.http.id
    Stage = aws_apigatewayv2_stage.default.name
  }

  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = 1
  treat_missing_data  = "notBreaching"

  alarm_actions = local.alarm_actions
  ok_actions    = local.alarm_actions
}

# Email notification, only when alarm_email is set.

resource "aws_sns_topic" "alarms" {
  #checkov:skip=CKV_AWS_26:CloudWatch alarms cannot publish to a topic encrypted with the AWS-managed SNS key, and a customer-managed key costs about $1/month idle. Messages hold only alarm metadata.
  count = local.notify ? 1 : 0
  name  = "${local.name}-alarms"
}

resource "aws_sns_topic_subscription" "alarm_email" {
  count     = local.notify ? 1 : 0
  topic_arn = aws_sns_topic.alarms[0].arn
  protocol  = "email"
  endpoint  = var.alarm_email
}
