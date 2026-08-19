variable "name_prefix" {
  description = "Prefix applied to all resource names, e.g. \"rennie-content-dev\"."
  type        = string
}

variable "agent_name" {
  description = "Short agent identifier, e.g. \"writer\", \"reviewer\", \"orchestrator\". Used in resource names and IAM scoping."
  type        = string
}

variable "model_id" {
  description = "Bedrock model id this agent should call. Passed to the container as the BEDROCK_MODEL_ID env var."
  type        = string
}

variable "aws_region" {
  description = "AWS region the runtime, ECR repo, and Bedrock model calls live in."
  type        = string
}

variable "image_tag" {
  description = "Tag of the image already pushed to this agent's ECR repo. The ECR repo must exist and contain this tag before the runtime resource is created (see module README for the two-step apply)."
  type        = string
  default     = "latest"
}

variable "environment_variables" {
  description = "Extra environment variables to inject into the container, merged with the defaults (BEDROCK_MODEL_ID, AWS_REGION)."
  type        = map(string)
  default     = {}
}

variable "invoke_runtime_arns" {
  description = "Agent Runtime ARNs this agent is allowed to call via bedrock-agentcore:InvokeAgentRuntime (e.g. the Orchestrator calling Writer/Reviewer). Leave empty for leaf agents that don't call other agents."
  type        = list(string)
  default     = []
}

variable "dynamodb_update_table_arns" {
  description = "DynamoDB table ARNs this agent may run UpdateItem against (e.g. the Orchestrator writing live \"which sub-agent is working now\" progress to content_jobs). Leave empty for agents that don't write progress directly."
  type        = list(string)
  default     = []
}

variable "allow_invoke_by_role_arns" {
  description = "IAM role ARNs allowed to call THIS agent's runtime, granted via a resource-based policy on the runtime itself (required in addition to the caller's own identity-based policy — see resource_policy.tf). E.g. Writer/Reviewer list the Orchestrator's execution role here. Leave empty for agents nothing else calls."
  type        = list(string)
  default     = []
}

variable "idle_runtime_session_timeout" {
  description = "Seconds a runtime session can sit idle before being reclaimed (60-28800). Lower = less standing compute if a session is abandoned."
  type        = number
  default     = 900
}

variable "max_lifetime" {
  description = "Max seconds a single runtime session may live, regardless of activity (60-28800)."
  type        = number
  default     = 3600
}

variable "ecr_untagged_image_expiry_days" {
  description = "Days to retain untagged ECR images before they're expired, to keep storage cost from growing across rebuilds."
  type        = number
  default     = 3
}

variable "tags" {
  description = "Tags applied to all resources created by this module."
  type        = map(string)
  default     = {}
}
