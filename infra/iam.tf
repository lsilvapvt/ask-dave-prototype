# One role per Lambda function, each allowed only what that function does.
# history: read the history/ prefix of the data bucket and write its own logs.
# chat (next iteration): read the one LLM key secret and write under history/.

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
