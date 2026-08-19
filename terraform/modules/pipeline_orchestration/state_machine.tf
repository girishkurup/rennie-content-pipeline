# Content pipeline: brief -> AI-reviewed draft -> human review -> either
# finalize (approved) or revise-and-review-again, up to
# max_human_review_iterations before escalating instead of looping forever.
#
# Built with jsonencode(...) rather than a hand-written ASL JSON file/
# templatefile() so HCL's own syntax checking catches structural mistakes
# instead of silent string-escaping bugs.

locals {
  lambda_retry = [
    {
      ErrorEquals     = ["Lambda.ServiceException", "Lambda.AWSLambdaException", "Lambda.SdkClientException", "Lambda.TooManyRequestsException"]
      IntervalSeconds = 2
      MaxAttempts     = 3
      BackoffRate     = 2
    }
  ]

  # Without this, a failure/timeout in pipeline_task_writer (e.g. the
  # Orchestrator's AI loop running long) left the job stuck showing
  # "queued" forever in the UI — chat_handler sets that status once at
  # creation and nothing else ever updated it if the pipeline died before
  # its own first DynamoDB write. States.ALL after Retry is exhausted means
  # genuine failures (not just transient ones already handled above).
  task_writer_catch = [
    {
      ErrorEquals = ["States.ALL"]
      ResultPath  = "$.error_info"
      Next        = "MarkFailed"
    }
  ]

  state_machine_definition = {
    Comment = "Content production pipeline for ${var.name_prefix}"
    StartAt = "ProduceInitialDraft"
    States = {
      ProduceInitialDraft = {
        Type     = "Task"
        Resource = aws_lambda_function.task_writer.arn
        Parameters = {
          "job_id.$" = "$.job_id"
          "brief.$"  = "$.brief"
          mode       = "initial"
        }
        ResultPath = "$.draft_result"
        Retry      = local.lambda_retry
        Catch      = local.task_writer_catch
        Next       = "PrepareHumanReview"
      }

      PrepareHumanReview = {
        Type     = "Task"
        Resource = "arn:${local.partition}:states:::lambda:invoke.waitForTaskToken"
        Parameters = {
          FunctionName = aws_lambda_function.task_reviewer.arn
          Payload = {
            "job_id.$"     = "$.job_id"
            "draft.$"      = "$.draft_result.draft"
            "task_token.$" = "$$.Task.Token"
          }
        }
        ResultPath = "$.human_decision"
        Retry      = local.lambda_retry
        Next       = "CheckHumanDecision"
      }

      CheckHumanDecision = {
        Type = "Choice"
        Choices = [
          {
            Variable      = "$.human_decision.approved"
            BooleanEquals = true
            Next          = "FinalizeApproved"
          },
          {
            Variable                 = "$.human_decision.human_review_rounds"
            NumericGreaterThanEquals = var.max_human_review_iterations
            Next                     = "FinalizeEscalated"
          }
        ]
        Default = "ReviseDraft"
      }

      ReviseDraft = {
        Type     = "Task"
        Resource = aws_lambda_function.task_writer.arn
        Parameters = {
          "job_id.$"             = "$.job_id"
          "brief.$"              = "$.brief"
          "previous_draft.$"     = "$.draft_result.draft"
          "feedback.$"           = "$.human_decision.feedback"
          "human_review_round.$" = "$.human_decision.human_review_rounds"
          mode                   = "revise"
        }
        ResultPath = "$.draft_result"
        Retry      = local.lambda_retry
        Catch      = local.task_writer_catch
        Next       = "PrepareHumanReview"
      }

      MarkFailed = {
        Type     = "Task"
        Resource = aws_lambda_function.finalize.arn
        Parameters = {
          "job_id.$" = "$.job_id"
          draft      = "Generation failed — see CloudWatch logs for pipeline-task-writer around this job's timestamps."
          outcome    = "failed"
        }
        Retry = local.lambda_retry
        End   = true
      }

      FinalizeApproved = {
        Type     = "Task"
        Resource = aws_lambda_function.finalize.arn
        Parameters = {
          "job_id.$" = "$.job_id"
          "draft.$"  = "$.draft_result.draft"
          outcome    = "completed"
        }
        Retry = local.lambda_retry
        End   = true
      }

      FinalizeEscalated = {
        Type     = "Task"
        Resource = aws_lambda_function.finalize.arn
        Parameters = {
          "job_id.$" = "$.job_id"
          "draft.$"  = "$.draft_result.draft"
          outcome    = "escalated"
        }
        Retry = local.lambda_retry
        End   = true
      }
    }
  }
}

resource "aws_cloudwatch_log_group" "state_machine" {
  name              = "/aws/vendedlogs/states/${var.name_prefix}-content-pipeline"
  retention_in_days = var.log_retention_days
  tags              = var.tags
}

data "aws_iam_policy_document" "state_machine_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["states.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "state_machine_exec" {
  statement {
    sid     = "InvokePipelineLambdas"
    effect  = "Allow"
    actions = ["lambda:InvokeFunction"]
    resources = [
      aws_lambda_function.task_writer.arn,
      aws_lambda_function.task_reviewer.arn,
      aws_lambda_function.finalize.arn,
    ]
  }

  statement {
    sid    = "Logging"
    effect = "Allow"
    actions = [
      "logs:CreateLogDelivery",
      "logs:GetLogDelivery",
      "logs:UpdateLogDelivery",
      "logs:DeleteLogDelivery",
      "logs:ListLogDeliveries",
      "logs:PutResourcePolicy",
      "logs:DescribeResourcePolicies",
      "logs:DescribeLogGroups",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role" "state_machine" {
  name               = "${var.name_prefix}-content-pipeline-exec"
  assume_role_policy = data.aws_iam_policy_document.state_machine_trust.json
  tags               = var.tags
}

resource "aws_iam_role_policy" "state_machine" {
  name   = "content-pipeline-policy"
  role   = aws_iam_role.state_machine.id
  policy = data.aws_iam_policy_document.state_machine_exec.json
}

resource "aws_sfn_state_machine" "content_pipeline" {
  name       = "${var.name_prefix}-content-pipeline"
  role_arn   = aws_iam_role.state_machine.arn
  definition = jsonencode(local.state_machine_definition)

  logging_configuration {
    log_destination        = "${aws_cloudwatch_log_group.state_machine.arn}:*"
    include_execution_data = true
    level                  = "ALL"
  }

  tags = var.tags
}
