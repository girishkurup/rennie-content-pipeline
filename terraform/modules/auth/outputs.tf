output "user_pool_id" {
  value = aws_cognito_user_pool.this.id
}

output "user_pool_arn" {
  value = aws_cognito_user_pool.this.arn
}

output "app_client_id" {
  value = aws_cognito_user_pool_client.spa.id
}

output "hosted_ui_domain" {
  value = "${aws_cognito_user_pool_domain.this.domain}.auth.${data.aws_region.current.region}.amazoncognito.com"
}

output "reviewers_group_name" {
  value = aws_cognito_user_group.reviewers.name
}

output "requesters_group_name" {
  value = aws_cognito_user_group.requesters.name
}

data "aws_region" "current" {}
