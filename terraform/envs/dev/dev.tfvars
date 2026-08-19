aws_region   = "us-east-1"
environment  = "dev"
project_name = "rennie-content"

# Confirm these model ids are enabled under Bedrock > Model access before applying.
bedrock_writer_model_id       = "us.anthropic.claude-sonnet-4-5-20250929-v1:0"
bedrock_reviewer_model_id     = "us.anthropic.claude-sonnet-4-5-20250929-v1:0"
bedrock_orchestrator_model_id = "us.anthropic.claude-sonnet-4-5-20250929-v1:0"
bedrock_embedding_model_id    = "amazon.titan-embed-text-v2:0"

max_ai_review_iterations    = 3
max_human_review_iterations = 3

agent_image_tag = "phase7"
alert_email     = ""
