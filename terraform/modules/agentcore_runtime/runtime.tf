# NOTE on apply ordering: this resource requires var.image_tag to already
# exist in aws_ecr_repository.this at apply time (AgentCore validates the
# image on create/update). First-time deploy is a two-step apply:
#   1. terraform apply -target=module.<agent>.aws_ecr_repository.this
#   2. docker build/push the image to the now-existing repo
#   3. terraform apply (full)
# See docs/deployment.md.

resource "aws_bedrockagentcore_agent_runtime" "this" {
  # Must start with a letter and contain only letters, numbers, underscores.
  agent_runtime_name = replace("${var.name_prefix}_${var.agent_name}", "-", "_")
  description        = "${var.agent_name} agent runtime"
  role_arn           = aws_iam_role.execution.arn
  region             = var.aws_region

  agent_runtime_artifact {
    container_configuration {
      container_uri = "${aws_ecr_repository.this.repository_url}:${var.image_tag}"
    }
  }

  network_configuration {
    network_mode = "PUBLIC"
  }

  protocol_configuration {
    server_protocol = "HTTP"
  }

  lifecycle_configuration {
    idle_runtime_session_timeout = var.idle_runtime_session_timeout
    max_lifetime                 = var.max_lifetime
  }

  environment_variables = merge(
    {
      BEDROCK_MODEL_ID = var.model_id
      AWS_REGION       = var.aws_region
    },
    var.environment_variables,
  )

  tags = var.tags

  depends_on = [aws_iam_role_policy.execution]
}
