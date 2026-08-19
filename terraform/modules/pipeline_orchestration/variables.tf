variable "name_prefix" {
  description = "Prefix applied to all resource names, e.g. \"rennie-content-dev\"."
  type        = string
}

variable "aws_region" {
  type = string
}

variable "content_jobs_table_name" {
  type = string
}

variable "content_jobs_table_arn" {
  type = string
}

variable "writer_runtime_arn" {
  description = "Writer agent's AgentCore Runtime ARN — called directly for human-feedback revisions."
  type        = string
}

variable "orchestrator_runtime_arn" {
  description = "Orchestrator agent's AgentCore Runtime ARN — called for the initial AI-reviewed draft."
  type        = string
}

variable "max_human_review_iterations" {
  description = "Max times a human rejection sends the draft back to the Writer before the job is escalated instead of looping forever."
  type        = number
}

variable "log_retention_days" {
  type    = number
  default = 14
}

variable "tags" {
  type    = map(string)
  default = {}
}
