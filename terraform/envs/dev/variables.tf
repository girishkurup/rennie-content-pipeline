variable "aws_region" {
  description = "AWS region. Bedrock AgentCore + the chosen Claude model must both be available here."
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Short environment name, used as a suffix on most resource names."
  type        = string
  default     = "dev"
}

variable "project_name" {
  description = "Short project slug used as a prefix on resource names."
  type        = string
  default     = "rennie-content"
}

# ---------------------------------------------------------------------------
# Bedrock models
# ---------------------------------------------------------------------------

variable "bedrock_writer_model_id" {
  description = "Bedrock model id (inference profile or foundation model ARN suffix) used by the Writer agent. Confirm this model is enabled under Bedrock > Model access in your account."
  type        = string
  default     = "us.anthropic.claude-sonnet-4-5-20250929-v1:0"
}

variable "bedrock_reviewer_model_id" {
  description = "Bedrock model id used by the Reviewer agent."
  type        = string
  default     = "us.anthropic.claude-sonnet-4-5-20250929-v1:0"
}

variable "bedrock_orchestrator_model_id" {
  description = "Bedrock model id used by the Orchestrator agent."
  type        = string
  default     = "us.anthropic.claude-sonnet-4-5-20250929-v1:0"
}

variable "bedrock_embedding_model_id" {
  description = "Bedrock embedding model id used by the Knowledge Base."
  type        = string
  default     = "amazon.titan-embed-text-v2:0"
}

# ---------------------------------------------------------------------------
# Retry / pipeline limits
# ---------------------------------------------------------------------------

variable "max_ai_review_iterations" {
  description = "Max number of Writer<->Reviewer AI feedback loops before falling through to human review anyway."
  type        = number
  default     = 3
}

variable "max_human_review_iterations" {
  description = "Max number of times a human rejection sends the draft back to the Writer."
  type        = number
  default     = 3
}

# ---------------------------------------------------------------------------
# Container images (built/pushed out of band, see docs/deployment.md)
# ---------------------------------------------------------------------------

variable "agent_image_tag" {
  description = "Tag applied to all three agent container images on each deploy."
  type        = string
  default     = "latest"
}

variable "alert_email" {
  description = "Optional email address subscribed to pipeline failure alarms. Leave empty to skip."
  type        = string
  default     = ""
}
