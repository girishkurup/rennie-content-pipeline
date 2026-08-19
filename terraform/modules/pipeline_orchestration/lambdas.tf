data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition
  lambda_src = "${path.module}/../../../lambdas"
}

# ---------------------------------------------------------------------------
# pipeline_task_writer — calls Orchestrator (initial) or Writer (revision)
# ---------------------------------------------------------------------------

data "archive_file" "task_writer" {
  type        = "zip"
  source_dir  = "${local.lambda_src}/pipeline_task_writer"
  output_path = "${path.module}/.build/pipeline_task_writer.zip"
}

resource "aws_iam_role" "task_writer" {
  name               = "${var.name_prefix}-pipeline-task-writer-exec"
  assume_role_policy = data.aws_iam_policy_document.lambda_trust.json
  tags               = var.tags
}

data "aws_iam_policy_document" "task_writer" {
  statement {
    sid       = "DynamoDBUpdateContentJobs"
    effect    = "Allow"
    actions   = ["dynamodb:UpdateItem"]
    resources = [var.content_jobs_table_arn]
  }

  statement {
    sid     = "InvokeWriterAndOrchestrator"
    effect  = "Allow"
    actions = ["bedrock-agentcore:InvokeAgentRuntime", "bedrock-agentcore:InvokeAgentRuntimeForUser"]
    # Both the bare runtime ARN and its runtime-endpoint sub-resource are
    # required — IAM evaluates InvokeAgentRuntime against the endpoint ARN
    # (<runtime_arn>/runtime-endpoint/DEFAULT), not the bare one. See the
    # matching note in modules/agentcore_runtime/iam.tf.
    resources = [
      var.writer_runtime_arn,
      "${var.writer_runtime_arn}/runtime-endpoint/*",
      var.orchestrator_runtime_arn,
      "${var.orchestrator_runtime_arn}/runtime-endpoint/*",
    ]
  }

  statement {
    sid       = "WriteArtifacts"
    effect    = "Allow"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.artifacts.arn}/*"]
  }
}

resource "aws_iam_role_policy" "task_writer" {
  name   = "pipeline-task-writer-policy"
  role   = aws_iam_role.task_writer.id
  policy = data.aws_iam_policy_document.task_writer.json
}

resource "aws_iam_role_policy_attachment" "task_writer_logs" {
  role       = aws_iam_role.task_writer.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_cloudwatch_log_group" "task_writer" {
  name              = "/aws/lambda/${var.name_prefix}-pipeline-task-writer"
  retention_in_days = var.log_retention_days
  tags              = var.tags
}

resource "aws_lambda_function" "task_writer" {
  function_name = "${var.name_prefix}-pipeline-task-writer"
  role          = aws_iam_role.task_writer.arn
  handler       = "handler.handler"
  runtime       = "python3.12"
  # The Orchestrator's own AI-review loop chains several sequential Bedrock
  # calls (draft -> review -> maybe revise -> review again, now also
  # optionally fetch_url first) — 120s measured too tight in practice (saw
  # real 120000ms timeouts under concurrent test load), bumped to 300s. Still
  # too tight: a real job hit the 300s ceiling too, driven by Bedrock
  # throttling under concurrent load (see the retry/backoff added in
  # agents/orchestrator/agent.py) adding real wall-clock time on top of the
  # AI loop's normal ~150-170s. Bumped again with more headroom. Lambda max
  # is 900s.
  timeout          = 480
  filename         = data.archive_file.task_writer.output_path
  source_code_hash = data.archive_file.task_writer.output_base64sha256

  environment {
    # AWS_REGION itself is set automatically by the Lambda runtime — no need
    # to pass it explicitly (Terraform would reject it as a reserved key
    # anyway).
    variables = {
      WRITER_RUNTIME_ARN       = var.writer_runtime_arn
      ORCHESTRATOR_RUNTIME_ARN = var.orchestrator_runtime_arn
      CONTENT_JOBS_TABLE       = var.content_jobs_table_name
      ARTIFACTS_BUCKET         = aws_s3_bucket.artifacts.bucket
    }
  }

  depends_on = [aws_cloudwatch_log_group.task_writer]
  tags       = var.tags
}

# ---------------------------------------------------------------------------
# pipeline_task_reviewer — persists the waitForTaskToken token for a human
# to act on later via review_handler
# ---------------------------------------------------------------------------

data "archive_file" "task_reviewer" {
  type        = "zip"
  source_dir  = "${local.lambda_src}/pipeline_task_reviewer"
  output_path = "${path.module}/.build/pipeline_task_reviewer.zip"
}

resource "aws_iam_role" "task_reviewer" {
  name               = "${var.name_prefix}-pipeline-task-reviewer-exec"
  assume_role_policy = data.aws_iam_policy_document.lambda_trust.json
  tags               = var.tags
}

data "aws_iam_policy_document" "task_reviewer" {
  statement {
    sid       = "DynamoDBUpdateContentJobs"
    effect    = "Allow"
    actions   = ["dynamodb:UpdateItem"]
    resources = [var.content_jobs_table_arn]
  }
}

resource "aws_iam_role_policy" "task_reviewer" {
  name   = "pipeline-task-reviewer-policy"
  role   = aws_iam_role.task_reviewer.id
  policy = data.aws_iam_policy_document.task_reviewer.json
}

resource "aws_iam_role_policy_attachment" "task_reviewer_logs" {
  role       = aws_iam_role.task_reviewer.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_cloudwatch_log_group" "task_reviewer" {
  name              = "/aws/lambda/${var.name_prefix}-pipeline-task-reviewer"
  retention_in_days = var.log_retention_days
  tags              = var.tags
}

resource "aws_lambda_function" "task_reviewer" {
  function_name    = "${var.name_prefix}-pipeline-task-reviewer"
  role             = aws_iam_role.task_reviewer.arn
  handler          = "handler.handler"
  runtime          = "python3.12"
  timeout          = 15
  filename         = data.archive_file.task_reviewer.output_path
  source_code_hash = data.archive_file.task_reviewer.output_base64sha256

  environment {
    variables = {
      CONTENT_JOBS_TABLE = var.content_jobs_table_name
    }
  }

  depends_on = [aws_cloudwatch_log_group.task_reviewer]
  tags       = var.tags
}

# ---------------------------------------------------------------------------
# pipeline_finalize — marks the job completed or escalated
# ---------------------------------------------------------------------------

data "archive_file" "finalize" {
  type        = "zip"
  source_dir  = "${local.lambda_src}/pipeline_finalize"
  output_path = "${path.module}/.build/pipeline_finalize.zip"
}

resource "aws_iam_role" "finalize" {
  name               = "${var.name_prefix}-pipeline-finalize-exec"
  assume_role_policy = data.aws_iam_policy_document.lambda_trust.json
  tags               = var.tags
}

data "aws_iam_policy_document" "finalize" {
  statement {
    sid       = "DynamoDBUpdateContentJobs"
    effect    = "Allow"
    actions   = ["dynamodb:UpdateItem"]
    resources = [var.content_jobs_table_arn]
  }

  statement {
    sid       = "WriteArtifacts"
    effect    = "Allow"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.artifacts.arn}/*"]
  }
}

resource "aws_iam_role_policy" "finalize" {
  name   = "pipeline-finalize-policy"
  role   = aws_iam_role.finalize.id
  policy = data.aws_iam_policy_document.finalize.json
}

resource "aws_iam_role_policy_attachment" "finalize_logs" {
  role       = aws_iam_role.finalize.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_cloudwatch_log_group" "finalize" {
  name              = "/aws/lambda/${var.name_prefix}-pipeline-finalize"
  retention_in_days = var.log_retention_days
  tags              = var.tags
}

resource "aws_lambda_function" "finalize" {
  function_name    = "${var.name_prefix}-pipeline-finalize"
  role             = aws_iam_role.finalize.arn
  handler          = "handler.handler"
  runtime          = "python3.12"
  timeout          = 15
  filename         = data.archive_file.finalize.output_path
  source_code_hash = data.archive_file.finalize.output_base64sha256

  environment {
    variables = {
      CONTENT_JOBS_TABLE = var.content_jobs_table_name
      ARTIFACTS_BUCKET   = aws_s3_bucket.artifacts.bucket
    }
  }

  depends_on = [aws_cloudwatch_log_group.finalize]
  tags       = var.tags
}

# ---------------------------------------------------------------------------
# Shared Lambda trust policy
# ---------------------------------------------------------------------------

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
