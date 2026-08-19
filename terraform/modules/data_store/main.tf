# ---------------------------------------------------------------------------
# conversations: one item per conversation. Lets a user list every
# conversation they've ever had and resume one after any amount of time.
#   PK: user_id       (Cognito sub)
#   SK: conversation_id
# ---------------------------------------------------------------------------
resource "aws_dynamodb_table" "conversations" {
  name         = "${var.name_prefix}-conversations"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "user_id"
  range_key    = "conversation_id"

  attribute {
    name = "user_id"
    type = "S"
  }

  attribute {
    name = "conversation_id"
    type = "S"
  }

  point_in_time_recovery {
    enabled = true
  }

  server_side_encryption {
    enabled = true
  }
}

# ---------------------------------------------------------------------------
# messages: full transcript of every conversation.
#   PK: conversation_id
#   SK: sort_key = "<iso8601-timestamp>#<message_id>"  (naturally orders history)
# ---------------------------------------------------------------------------
resource "aws_dynamodb_table" "messages" {
  name         = "${var.name_prefix}-messages"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "conversation_id"
  range_key    = "sort_key"

  attribute {
    name = "conversation_id"
    type = "S"
  }

  attribute {
    name = "sort_key"
    type = "S"
  }

  point_in_time_recovery {
    enabled = true
  }

  server_side_encryption {
    enabled = true
  }
}

# ---------------------------------------------------------------------------
# content_jobs: one item per content-generation pipeline run (the state the
# Step Functions state machine reads/writes at every transition).
#   PK: job_id
#   GSI: by_status         -> reviewer dashboard queue (status, updated_at)
#   GSI: by_conversation    -> "what jobs came out of this conversation"
# ---------------------------------------------------------------------------
resource "aws_dynamodb_table" "content_jobs" {
  name         = "${var.name_prefix}-content-jobs"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "job_id"

  attribute {
    name = "job_id"
    type = "S"
  }

  attribute {
    name = "status"
    type = "S"
  }

  attribute {
    name = "updated_at"
    type = "S"
  }

  attribute {
    name = "conversation_id"
    type = "S"
  }

  global_secondary_index {
    name            = "by_status"
    hash_key        = "status"
    range_key       = "updated_at"
    projection_type = "ALL"
  }

  global_secondary_index {
    name            = "by_conversation"
    hash_key        = "conversation_id"
    range_key       = "updated_at"
    projection_type = "ALL"
  }

  point_in_time_recovery {
    enabled = true
  }

  server_side_encryption {
    enabled = true
  }
}
