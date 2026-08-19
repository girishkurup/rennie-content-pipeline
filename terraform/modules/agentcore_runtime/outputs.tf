output "ecr_repository_url" {
  description = "Push images here: `docker push <this>:<tag>`, matching var.image_tag."
  value       = aws_ecr_repository.this.repository_url
}

output "ecr_repository_arn" {
  value = aws_ecr_repository.this.arn
}

output "agent_runtime_arn" {
  value = aws_bedrockagentcore_agent_runtime.this.agent_runtime_arn
}

output "agent_runtime_id" {
  value = aws_bedrockagentcore_agent_runtime.this.agent_runtime_id
}

output "execution_role_arn" {
  value = aws_iam_role.execution.arn
}
