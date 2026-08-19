data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  partition  = data.aws_partition.current.partition
  account_id = data.aws_caller_identity.current.account_id
}

# Trust policy mirrors what AWS's own agentcore CLI generates: only the
# Bedrock AgentCore service may assume this role, and only on behalf of
# AgentCore resources in this account/region.
data "aws_iam_policy_document" "trust" {
  statement {
    sid     = "AssumeRolePolicy"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["bedrock-agentcore.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:${local.partition}:bedrock-agentcore:${var.aws_region}:${local.account_id}:*"]
    }
  }
}

resource "aws_iam_role" "execution" {
  name               = "${var.name_prefix}-${var.agent_name}-agentcore-exec"
  assume_role_policy = data.aws_iam_policy_document.trust.json
  description        = "Execution role for the ${var.agent_name} agent's Bedrock AgentCore Runtime."
  tags               = var.tags
}

# Least-privilege set for a container-deployed agent that calls Bedrock
# models and uses AgentCore's built-in identity/token-vault plumbing.
# Adapted from the policy AWS's own agentcore CLI generates for an
# equivalent deployment; memory and code-interpreter permissions are
# intentionally omitted since this agent doesn't use those features yet.
data "aws_iam_policy_document" "execution" {
  statement {
    sid       = "ECRImageAccess"
    effect    = "Allow"
    actions   = ["ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer"]
    resources = [aws_ecr_repository.this.arn]
  }

  statement {
    sid       = "ECRTokenAccess"
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    effect  = "Allow"
    actions = ["logs:DescribeLogStreams", "logs:CreateLogGroup"]
    resources = [
      "arn:${local.partition}:logs:${var.aws_region}:${local.account_id}:log-group:/aws/bedrock-agentcore/runtimes/*",
    ]
  }

  statement {
    effect    = "Allow"
    actions   = ["logs:DescribeLogGroups"]
    resources = ["arn:${local.partition}:logs:${var.aws_region}:${local.account_id}:log-group:*"]
  }

  statement {
    effect  = "Allow"
    actions = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = [
      "arn:${local.partition}:logs:${var.aws_region}:${local.account_id}:log-group:/aws/bedrock-agentcore/runtimes/*:log-stream:*",
    ]
  }

  statement {
    sid     = "CloudWatchLogsPutResourcePolicy"
    effect  = "Allow"
    actions = ["logs:PutResourcePolicy"]
    resources = [
      "arn:${local.partition}:logs:${var.aws_region}:${local.account_id}:log-group:/aws/bedrock-agentcore/runtimes/${var.agent_name}-*",
    ]
  }

  statement {
    effect    = "Allow"
    actions   = ["xray:PutTraceSegments", "xray:PutTelemetryRecords", "xray:GetSamplingRules", "xray:GetSamplingTargets"]
    resources = ["*"]
  }

  statement {
    effect    = "Allow"
    actions   = ["cloudwatch:PutMetricData"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "cloudwatch:namespace"
      values   = ["bedrock-agentcore"]
    }
  }

  statement {
    sid     = "BedrockAgentCoreIdentityGetResourceApiKey"
    effect  = "Allow"
    actions = ["bedrock-agentcore:GetResourceApiKey"]
    resources = [
      "arn:${local.partition}:bedrock-agentcore:${var.aws_region}:${local.account_id}:token-vault/default",
      "arn:${local.partition}:bedrock-agentcore:${var.aws_region}:${local.account_id}:token-vault/default/apikeycredentialprovider/*",
      "arn:${local.partition}:bedrock-agentcore:${var.aws_region}:${local.account_id}:workload-identity-directory/default",
      "arn:${local.partition}:bedrock-agentcore:${var.aws_region}:${local.account_id}:workload-identity-directory/default/workload-identity/*",
    ]
  }

  statement {
    sid     = "BedrockAgentCoreIdentityGetCredentialProviderClientSecret"
    effect  = "Allow"
    actions = ["secretsmanager:GetSecretValue"]
    resources = [
      "arn:${local.partition}:secretsmanager:${var.aws_region}:${local.account_id}:secret:bedrock-agentcore-identity!default/oauth2/*",
      "arn:${local.partition}:secretsmanager:${var.aws_region}:${local.account_id}:secret:bedrock-agentcore-identity!default/apikey/*",
    ]
  }

  statement {
    sid     = "BedrockAgentCoreIdentityGetResourceOauth2Token"
    effect  = "Allow"
    actions = ["bedrock-agentcore:GetResourceOauth2Token"]
    resources = [
      "arn:${local.partition}:bedrock-agentcore:${var.aws_region}:${local.account_id}:token-vault/default",
      "arn:${local.partition}:bedrock-agentcore:${var.aws_region}:${local.account_id}:token-vault/default/oauth2credentialprovider/*",
      "arn:${local.partition}:bedrock-agentcore:${var.aws_region}:${local.account_id}:workload-identity-directory/default",
      "arn:${local.partition}:bedrock-agentcore:${var.aws_region}:${local.account_id}:workload-identity-directory/default/workload-identity/${var.agent_name}-*",
    ]
  }

  statement {
    sid     = "BedrockAgentCoreIdentity"
    effect  = "Allow"
    actions = ["bedrock-agentcore:GetWorkloadAccessTokenForUserId"]
    resources = [
      "arn:${local.partition}:bedrock-agentcore:${var.aws_region}:${local.account_id}:workload-identity-directory/default",
      "arn:${local.partition}:bedrock-agentcore:${var.aws_region}:${local.account_id}:workload-identity-directory/default/workload-identity/${var.agent_name}-*",
    ]
  }

  statement {
    sid     = "BedrockModelInvocation"
    effect  = "Allow"
    actions = ["bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream", "bedrock:ApplyGuardrail"]
    resources = [
      "arn:${local.partition}:bedrock:*::foundation-model/*",
      "arn:${local.partition}:bedrock:${var.aws_region}:${local.account_id}:*",
    ]
  }

  statement {
    sid       = "MarketplaceSubscribeOnFirstCall"
    effect    = "Allow"
    actions   = ["aws-marketplace:ViewSubscriptions", "aws-marketplace:Subscribe"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:CalledViaLast"
      values   = ["bedrock.amazonaws.com"]
    }
  }

  statement {
    sid       = "AwsJwtFederation"
    effect    = "Allow"
    actions   = ["sts:GetWebIdentityToken"]
    resources = ["*"]
  }

  # Only agents that call other agents (the Orchestrator) need this — leaf
  # agents like Writer/Reviewer leave var.invoke_runtime_arns empty and get
  # no such statement.
  dynamic "statement" {
    for_each = length(var.invoke_runtime_arns) > 0 ? [1] : []
    content {
      sid       = "InvokeChildAgentRuntimes"
      effect    = "Allow"
      actions   = ["bedrock-agentcore:InvokeAgentRuntime", "bedrock-agentcore:InvokeAgentRuntimeForUser"]
      resources = var.invoke_runtime_arns
    }
  }

  # Only agents writing their own progress back to DynamoDB (the
  # Orchestrator, for the frontend's "which agent is working now" display)
  # need this — leaf agents leave var.dynamodb_update_table_arns empty.
  dynamic "statement" {
    for_each = length(var.dynamodb_update_table_arns) > 0 ? [1] : []
    content {
      sid       = "UpdateProgressTables"
      effect    = "Allow"
      actions   = ["dynamodb:UpdateItem"]
      resources = var.dynamodb_update_table_arns
    }
  }
}

resource "aws_iam_role_policy" "execution" {
  name   = "BedrockAgentCoreRuntimeExecutionPolicy-${var.agent_name}"
  role   = aws_iam_role.execution.id
  policy = data.aws_iam_policy_document.execution.json
}
