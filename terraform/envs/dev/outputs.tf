output "cognito_user_pool_id" {
  value = module.auth.user_pool_id
}

output "cognito_app_client_id" {
  value = module.auth.app_client_id
}

output "cognito_hosted_ui_domain" {
  value = module.auth.hosted_ui_domain
}

output "conversations_table_name" {
  value = module.data_store.conversations_table_name
}

output "messages_table_name" {
  value = module.data_store.messages_table_name
}

output "content_jobs_table_name" {
  value = module.data_store.content_jobs_table_name
}

output "api_endpoint" {
  value = module.api.api_endpoint
}

output "frontend_url" {
  value = "https://${module.frontend_hosting.cloudfront_domain_name}"
}

output "cloudfront_distribution_id" {
  description = "Needed to invalidate the cache after redeploying frontend/dist — see docs/deployment.md."
  value       = module.frontend_hosting.cloudfront_distribution_id
}
