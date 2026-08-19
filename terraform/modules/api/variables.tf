variable "name_prefix" {
  type = string
}

variable "aws_region" {
  type = string
}

variable "cognito_user_pool_id" {
  type = string
}

variable "cognito_app_client_id" {
  type = string
}

variable "conversations_table_name" {
  type = string
}

variable "conversations_table_arn" {
  type = string
}

variable "messages_table_name" {
  type = string
}

variable "messages_table_arn" {
  type = string
}

variable "content_jobs_table_name" {
  type = string
}

variable "content_jobs_table_arn" {
  type = string
}

variable "state_machine_arn" {
  type = string
}

variable "state_machine_name" {
  description = "Used to scope review_handler's states:StopExecution permission to this state machine's own executions."
  type        = string
}

variable "artifacts_bucket_name" {
  type = string
}

variable "artifacts_bucket_arn" {
  type = string
}

variable "allowed_cors_origins" {
  description = "Origins allowed to call this API (the frontend's URL). Defaults to the Vite dev server for local development before frontend_hosting exists."
  type        = list(string)
  default     = ["http://localhost:5173"]
}

variable "log_retention_days" {
  type    = number
  default = 14
}

variable "tags" {
  type    = map(string)
  default = {}
}
