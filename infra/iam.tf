# One role per Lambda function, each allowed only what that function does.
# history: read the history/ prefix of the data bucket and write its own logs.
# chat: read the one LLM key secret, write new objects under history/, write its own logs.

data "aws_iam_policy_document" "lambda_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "history" {
  name               = "${local.name}-history"
  description        = "GET /history Lambda: read-only access to saved history."
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
}

data "aws_iam_policy_document" "history" {
  statement {
    sid       = "ListHistoryPrefixOnly"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.data.arn]

    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["history/*"]
    }
  }

  statement {
    sid       = "ReadHistoryObjects"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.data.arn}/history/*"]
  }

  # Instead of the AWSLambdaBasicExecutionRole managed policy, which allows
  # creating and writing any log group in the account. No logs:CreateLogGroup:
  # Terraform owns the log group, so it is removed on destroy.
  statement {
    sid       = "WriteOwnLogGroupOnly"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.history.arn}:*"]
  }
}

resource "aws_iam_role_policy" "history" {
  name   = "history-least-privilege"
  role   = aws_iam_role.history.id
  policy = data.aws_iam_policy_document.history.json
}

resource "aws_iam_role" "chat" {
  name               = "${local.name}-chat"
  description        = "POST /chat Lambda: reads the LLM key and saves new history entries."
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
}

data "aws_iam_policy_document" "chat" {
  # The secret uses the AWS-managed Secrets Manager key, so no KMS permission is needed.
  statement {
    sid       = "ReadLlmKeyOnly"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_secretsmanager_secret.llm_api_key.arn]
  }

  # Write-only: chat can add history entries but cannot read, list, or delete them.
  statement {
    sid       = "WriteHistoryObjects"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.data.arn}/history/*"]
  }

  statement {
    sid       = "WriteOwnLogGroupOnly"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.chat.arn}:*"]
  }
}

resource "aws_iam_role_policy" "chat" {
  name   = "chat-least-privilege"
  role   = aws_iam_role.chat.id
  policy = data.aws_iam_policy_document.chat.json
}
