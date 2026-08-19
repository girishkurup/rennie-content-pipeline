# Bedrock AgentCore checks BOTH the caller's identity-based policy (see
# iam.tf's InvokeChildAgentRuntimes statement on the *caller's* role) AND a
# resource-based policy on the *target* runtime — much like Lambda resource
# policies. Leaf agents (Writer/Reviewer) that get called by the Orchestrator
# need this; the Orchestrator itself doesn't, since nothing calls it.
data "aws_iam_policy_document" "resource_policy" {
  count = length(var.allow_invoke_by_role_arns) > 0 ? 1 : 0

  # One statement PER caller role, not one statement with a list of
  # principals — AWS rejects multi-principal statements here
  # ("ValidationException: Invalid principal in policy"), unlike a normal
  # IAM policy. Each statement is also restricted to exactly one Resource
  # ARN, matching resource_arn below exactly ("Policy statement block must
  # contain exactly one resource ARN that matches the provided resource
  # ARN") — no runtime-endpoint sub-resource variant allowed here either,
  # unlike the identity-side policy.
  dynamic "statement" {
    for_each = { for arn in var.allow_invoke_by_role_arns : arn => arn }
    content {
      sid     = "AllowInvokeBy${md5(statement.value)}"
      effect  = "Allow"
      actions = ["bedrock-agentcore:InvokeAgentRuntime", "bedrock-agentcore:InvokeAgentRuntimeForUser"]

      principals {
        type        = "AWS"
        identifiers = [statement.value]
      }

      resources = [aws_bedrockagentcore_agent_runtime.this.agent_runtime_arn]
    }
  }
}

resource "aws_bedrockagentcore_resource_policy" "invoke" {
  count = length(var.allow_invoke_by_role_arns) > 0 ? 1 : 0

  resource_arn = aws_bedrockagentcore_agent_runtime.this.agent_runtime_arn
  policy       = data.aws_iam_policy_document.resource_policy[0].json
}
