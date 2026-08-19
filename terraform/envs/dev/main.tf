locals {
  name_prefix = "${var.project_name}-${var.environment}"

  # Computed as a plain string (not module.orchestrator_agent.execution_role_arn)
  # so Writer/Reviewer's resource policies can reference it without creating a
  # module dependency cycle: Writer/Reviewer -> needs Orchestrator's role ARN,
  # Orchestrator -> needs Writer/Reviewer's runtime ARNs. Must match the role
  # name aws_iam_role.execution builds in modules/agentcore_runtime/iam.tf.
  orchestrator_execution_role_arn = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:role/${local.name_prefix}-orchestrator-agentcore-exec"

  # Same plain-string trick, same reason: module.pipeline_orchestration needs
  # Writer/Orchestrator's runtime ARNs, so Writer/Orchestrator can't in turn
  # depend on module.pipeline_orchestration's role output without a cycle.
  # Must match the role name aws_iam_role.task_writer builds in
  # modules/pipeline_orchestration/lambdas.tf.
  pipeline_task_writer_role_arn = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:role/${local.name_prefix}-pipeline-task-writer-exec"
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}
data "aws_partition" "current" {}

# ---------------------------------------------------------------------------
# Foundational: data store + auth
# ---------------------------------------------------------------------------

module "data_store" {
  source      = "../../modules/data_store"
  name_prefix = local.name_prefix
}

module "auth" {
  source      = "../../modules/auth"
  name_prefix = local.name_prefix

  # localhost stays in the list for local `npm run dev` testing even once
  # the CloudFront domain is live.
  callback_urls = [
    "http://localhost:5173/callback",
    "https://${module.frontend_hosting.cloudfront_domain_name}/callback",
  ]
  logout_urls = [
    "http://localhost:5173/",
    "https://${module.frontend_hosting.cloudfront_domain_name}/",
  ]
}

# ---------------------------------------------------------------------------
# Writer agent (Phase 1 smoke test — reviewer/orchestrator follow once this
# proves the SDK/Terraform/AgentCore Runtime chain end-to-end)
# ---------------------------------------------------------------------------

module "writer_agent" {
  source = "../../modules/agentcore_runtime"

  name_prefix = local.name_prefix
  agent_name  = "writer"
  model_id    = var.bedrock_writer_model_id
  aws_region  = var.aws_region
  image_tag   = var.agent_image_tag

  # Identity-based policy on the caller's own role isn't sufficient on its
  # own — AgentCore also checks a resource-based policy on the target
  # runtime, granted here. Both the Orchestrator (AI review loop) and
  # pipeline_task_writer (direct calls for initial draft + human-feedback
  # revisions) call the Writer, so both need to be listed.
  allow_invoke_by_role_arns = [local.orchestrator_execution_role_arn, local.pipeline_task_writer_role_arn]
}

module "reviewer_agent" {
  source = "../../modules/agentcore_runtime"

  name_prefix = local.name_prefix
  agent_name  = "reviewer"
  model_id    = var.bedrock_reviewer_model_id
  aws_region  = var.aws_region
  image_tag   = var.agent_image_tag

  # Only the Orchestrator calls the Reviewer directly (as part of its AI
  # review loop) — pipeline_task_writer never does.
  allow_invoke_by_role_arns = [local.orchestrator_execution_role_arn]
}

module "orchestrator_agent" {
  source = "../../modules/agentcore_runtime"

  name_prefix = local.name_prefix
  agent_name  = "orchestrator"
  model_id    = var.bedrock_orchestrator_model_id
  aws_region  = var.aws_region
  image_tag   = var.agent_image_tag

  # The Orchestrator calls Writer/Reviewer directly rather than through its
  # own model, so it needs both their runtime ARNs (as env vars, to know who
  # to call) and IAM permission to actually invoke them.
  environment_variables = {
    WRITER_RUNTIME_ARN       = module.writer_agent.agent_runtime_arn
    REVIEWER_RUNTIME_ARN     = module.reviewer_agent.agent_runtime_arn
    MAX_AI_REVIEW_ITERATIONS = tostring(var.max_ai_review_iterations)
    # So the Orchestrator can write "Writer is drafting…" / "Reviewer is
    # checking round 2…" progress as it works, for the frontend to poll and
    # display — see dynamodb_update_table_arns below for the matching IAM.
    CONTENT_JOBS_TABLE = module.data_store.content_jobs_table_name
  }

  dynamodb_update_table_arns = [module.data_store.content_jobs_table_arn]

  # IAM evaluates InvokeAgentRuntime against the runtime-ENDPOINT
  # sub-resource ("<runtime_arn>/runtime-endpoint/DEFAULT"), not the bare
  # runtime ARN — confirmed via a live AccessDeniedException naming that
  # exact resource when only the bare ARN was granted.
  invoke_runtime_arns = [
    module.writer_agent.agent_runtime_arn,
    "${module.writer_agent.agent_runtime_arn}/runtime-endpoint/*",
    module.reviewer_agent.agent_runtime_arn,
    "${module.reviewer_agent.agent_runtime_arn}/runtime-endpoint/*",
  ]

  # pipeline_task_writer calls the Orchestrator directly for a job's initial
  # AI-reviewed draft (mode="initial") — same resource-policy requirement as
  # Writer/Reviewer above.
  allow_invoke_by_role_arns = [local.pipeline_task_writer_role_arn]
}

# ---------------------------------------------------------------------------
# Pipeline orchestration (Step Functions): brief -> AI-reviewed draft ->
# human review -> finalize, or revise-and-review-again up to
# max_human_review_iterations before escalating.
# ---------------------------------------------------------------------------

module "pipeline_orchestration" {
  source = "../../modules/pipeline_orchestration"

  name_prefix                 = local.name_prefix
  aws_region                  = var.aws_region
  content_jobs_table_name     = module.data_store.content_jobs_table_name
  content_jobs_table_arn      = module.data_store.content_jobs_table_arn
  writer_runtime_arn          = module.writer_agent.agent_runtime_arn
  orchestrator_runtime_arn    = module.orchestrator_agent.agent_runtime_arn
  max_human_review_iterations = var.max_human_review_iterations
}

# ---------------------------------------------------------------------------
# API (HTTP API + Cognito JWT authorizer + chat/history/review lambdas)
# ---------------------------------------------------------------------------

module "api" {
  source = "../../modules/api"

  name_prefix              = local.name_prefix
  aws_region               = var.aws_region
  cognito_user_pool_id     = module.auth.user_pool_id
  cognito_app_client_id    = module.auth.app_client_id
  conversations_table_name = module.data_store.conversations_table_name
  conversations_table_arn  = module.data_store.conversations_table_arn
  messages_table_name      = module.data_store.messages_table_name
  messages_table_arn       = module.data_store.messages_table_arn
  content_jobs_table_name  = module.data_store.content_jobs_table_name
  content_jobs_table_arn   = module.data_store.content_jobs_table_arn
  state_machine_arn        = module.pipeline_orchestration.state_machine_arn
  state_machine_name       = module.pipeline_orchestration.state_machine_name
  artifacts_bucket_name    = module.pipeline_orchestration.artifacts_bucket_name
  artifacts_bucket_arn     = module.pipeline_orchestration.artifacts_bucket_arn

  allowed_cors_origins = [
    "http://localhost:5173",
    "https://${module.frontend_hosting.cloudfront_domain_name}",
  ]
}

# ---------------------------------------------------------------------------
# Frontend hosting (S3 + CloudFront)
# ---------------------------------------------------------------------------

module "frontend_hosting" {
  source = "../../modules/frontend_hosting"

  name_prefix = local.name_prefix
}

# ---------------------------------------------------------------------------
# Knowledge Base (OpenSearch Serverless) — cost-sensitive: stood up only for
# one end-to-end ingestion/retrieval test at a time, then torn down right
# after (see [[cost-control-preference]] in project memory). Verified
# working end to end on 2026-08-18 (ingestion + semantic retrieval both
# confirmed against real queries) then destroyed — left commented out here
# rather than wired in, so a routine `terraform apply` for unrelated changes
# can't accidentally recreate it. Uncomment to stand it up again for another
# test.
#
# module "knowledge_base" {
#   source = "../../modules/knowledge_base"
#
#   name_prefix        = local.name_prefix
#   embedding_model_id = var.bedrock_embedding_model_id
# }
