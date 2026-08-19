data "aws_partition" "current" {}
data "aws_caller_identity" "current" {}

locals {
  partition  = data.aws_partition.current.partition
  account_id = data.aws_caller_identity.current.account_id
  lambda_src = "${path.module}/../../../lambdas"
}

data "aws_iam_policy_document" "lambda_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

# ---------------------------------------------------------------------------
# chat_handler — POST /chat
# ---------------------------------------------------------------------------

data "archive_file" "chat_handler" {
  type        = "zip"
  source_dir  = "${local.lambda_src}/chat_handler"
  output_path = "${path.module}/.build/chat_handler.zip"
}

resource "aws_iam_role" "chat_handler" {
  name               = "${var.name_prefix}-chat-handler-exec"
  assume_role_policy = data.aws_iam_policy_document.lambda_trust.json
  tags               = var.tags
}

data "aws_iam_policy_document" "chat_handler" {
  statement {
    sid       = "UpdateConversations"
    effect    = "Allow"
    actions   = ["dynamodb:UpdateItem"]
    resources = [var.conversations_table_arn]
  }

  statement {
    sid       = "WriteMessagesAndJobs"
    effect    = "Allow"
    actions   = ["dynamodb:PutItem"]
    resources = [var.messages_table_arn, var.content_jobs_table_arn]
  }

  statement {
    sid       = "StartPipeline"
    effect    = "Allow"
    actions   = ["states:StartExecution"]
    resources = [var.state_machine_arn]
  }
}

resource "aws_iam_role_policy" "chat_handler" {
  name   = "chat-handler-policy"
  role   = aws_iam_role.chat_handler.id
  policy = data.aws_iam_policy_document.chat_handler.json
}

resource "aws_iam_role_policy_attachment" "chat_handler_logs" {
  role       = aws_iam_role.chat_handler.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_cloudwatch_log_group" "chat_handler" {
  name              = "/aws/lambda/${var.name_prefix}-chat-handler"
  retention_in_days = var.log_retention_days
  tags              = var.tags
}

resource "aws_lambda_function" "chat_handler" {
  function_name    = "${var.name_prefix}-chat-handler"
  role             = aws_iam_role.chat_handler.arn
  handler          = "handler.handler"
  runtime          = "python3.12"
  timeout          = 15
  filename         = data.archive_file.chat_handler.output_path
  source_code_hash = data.archive_file.chat_handler.output_base64sha256

  environment {
    variables = {
      CONVERSATIONS_TABLE = var.conversations_table_name
      MESSAGES_TABLE      = var.messages_table_name
      CONTENT_JOBS_TABLE  = var.content_jobs_table_name
      STATE_MACHINE_ARN   = var.state_machine_arn
    }
  }

  depends_on = [aws_cloudwatch_log_group.chat_handler]
  tags       = var.tags
}

# ---------------------------------------------------------------------------
# history_handler — GET /conversations, /conversations/{id}/messages, /jobs, /jobs/{id}
# ---------------------------------------------------------------------------

data "archive_file" "history_handler" {
  type        = "zip"
  source_dir  = "${local.lambda_src}/history_handler"
  output_path = "${path.module}/.build/history_handler.zip"
}

resource "aws_iam_role" "history_handler" {
  name               = "${var.name_prefix}-history-handler-exec"
  assume_role_policy = data.aws_iam_policy_document.lambda_trust.json
  tags               = var.tags
}

data "aws_iam_policy_document" "history_handler" {
  statement {
    sid     = "ReadConversationsMessagesJobs"
    effect  = "Allow"
    actions = ["dynamodb:Query", "dynamodb:GetItem"]
    resources = [
      var.conversations_table_arn,
      var.messages_table_arn,
      var.content_jobs_table_arn,
      "${var.content_jobs_table_arn}/index/*", # by_status GSI
    ]
  }

  statement {
    sid    = "PresignArtifactDownloads"
    effect = "Allow"
    # generate_presigned_url signs locally, but the signature is only valid
    # if this role would itself be allowed to GetObject — the browser is
    # effectively borrowing this permission for the life of the URL.
    actions   = ["s3:GetObject"]
    resources = ["${var.artifacts_bucket_arn}/*"]
  }
}

resource "aws_iam_role_policy" "history_handler" {
  name   = "history-handler-policy"
  role   = aws_iam_role.history_handler.id
  policy = data.aws_iam_policy_document.history_handler.json
}

resource "aws_iam_role_policy_attachment" "history_handler_logs" {
  role       = aws_iam_role.history_handler.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_cloudwatch_log_group" "history_handler" {
  name              = "/aws/lambda/${var.name_prefix}-history-handler"
  retention_in_days = var.log_retention_days
  tags              = var.tags
}

resource "aws_lambda_function" "history_handler" {
  function_name    = "${var.name_prefix}-history-handler"
  role             = aws_iam_role.history_handler.arn
  handler          = "handler.handler"
  runtime          = "python3.12"
  timeout          = 15
  filename         = data.archive_file.history_handler.output_path
  source_code_hash = data.archive_file.history_handler.output_base64sha256

  environment {
    variables = {
      CONVERSATIONS_TABLE = var.conversations_table_name
      MESSAGES_TABLE      = var.messages_table_name
      CONTENT_JOBS_TABLE  = var.content_jobs_table_name
      ARTIFACTS_BUCKET    = var.artifacts_bucket_name
    }
  }

  depends_on = [aws_cloudwatch_log_group.history_handler]
  tags       = var.tags
}

# ---------------------------------------------------------------------------
# review_handler — POST /jobs/{job_id}/review (reviewers group only)
# ---------------------------------------------------------------------------

data "archive_file" "review_handler" {
  type        = "zip"
  source_dir  = "${local.lambda_src}/review_handler"
  output_path = "${path.module}/.build/review_handler.zip"
}

resource "aws_iam_role" "review_handler" {
  name               = "${var.name_prefix}-review-handler-exec"
  assume_role_policy = data.aws_iam_policy_document.lambda_trust.json
  tags               = var.tags
}

data "aws_iam_policy_document" "review_handler" {
  statement {
    sid       = "ReadWriteContentJobs"
    effect    = "Allow"
    actions   = ["dynamodb:GetItem", "dynamodb:UpdateItem"]
    resources = [var.content_jobs_table_arn]
  }

  statement {
    sid    = "ResumePausedExecution"
    effect = "Allow"
    # SendTaskSuccess/Failure address a specific paused task by an opaque
    # token, not by ARN — Step Functions doesn't support resource-level
    # scoping for this action, so it has to be "*".
    actions   = ["states:SendTaskSuccess", "states:SendTaskFailure"]
    resources = ["*"]
  }

  statement {
    sid       = "StopPipelineExecution"
    effect    = "Allow"
    actions   = ["states:StopExecution"]
    resources = ["arn:${local.partition}:states:${var.aws_region}:${local.account_id}:execution:${var.state_machine_name}:*"]
  }
}

resource "aws_iam_role_policy" "review_handler" {
  name   = "review-handler-policy"
  role   = aws_iam_role.review_handler.id
  policy = data.aws_iam_policy_document.review_handler.json
}

resource "aws_iam_role_policy_attachment" "review_handler_logs" {
  role       = aws_iam_role.review_handler.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_cloudwatch_log_group" "review_handler" {
  name              = "/aws/lambda/${var.name_prefix}-review-handler"
  retention_in_days = var.log_retention_days
  tags              = var.tags
}

resource "aws_lambda_function" "review_handler" {
  function_name    = "${var.name_prefix}-review-handler"
  role             = aws_iam_role.review_handler.arn
  handler          = "handler.handler"
  runtime          = "python3.12"
  timeout          = 15
  filename         = data.archive_file.review_handler.output_path
  source_code_hash = data.archive_file.review_handler.output_base64sha256

  environment {
    variables = {
      CONTENT_JOBS_TABLE = var.content_jobs_table_name
    }
  }

  depends_on = [aws_cloudwatch_log_group.review_handler]
  tags       = var.tags
}
