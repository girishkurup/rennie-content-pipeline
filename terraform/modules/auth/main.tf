resource "aws_cognito_user_pool" "this" {
  name = "${var.name_prefix}-users"

  username_attributes      = ["email"]
  auto_verified_attributes = ["email"]

  password_policy {
    minimum_length    = 12
    require_lowercase = true
    require_uppercase = true
    require_numbers   = true
    require_symbols   = true
  }

  account_recovery_setting {
    recovery_mechanism {
      name     = "verified_email"
      priority = 1
    }
  }

  admin_create_user_config {
    allow_admin_create_user_only = true # Bayer staff are provisioned by an admin, not self-signup
  }

  schema {
    name                = "email"
    attribute_data_type = "String"
    mutable             = true
    required            = true
  }
}

resource "random_string" "domain_suffix" {
  length  = 6
  special = false
  upper   = false
}

resource "aws_cognito_user_pool_domain" "this" {
  domain       = "${var.name_prefix}-${random_string.domain_suffix.result}"
  user_pool_id = aws_cognito_user_pool.this.id
}

# Requesters: can chat with the Orchestrator and view/resume their own conversations.
resource "aws_cognito_user_group" "requesters" {
  name         = "requesters"
  user_pool_id = aws_cognito_user_pool.this.id
  description  = "Can request content generation and view their own conversation history."
  precedence   = 20
}

# Reviewers: everything requesters can do, plus the human-review dashboard
# (approve/reject queued drafts). API Gateway Lambda handlers check the
# cognito:groups claim on review routes.
resource "aws_cognito_user_group" "reviewers" {
  name         = "reviewers"
  user_pool_id = aws_cognito_user_pool.this.id
  description  = "Can approve/reject drafts on the human review dashboard."
  precedence   = 10
}

resource "aws_cognito_user_pool_client" "spa" {
  name         = "${var.name_prefix}-spa-client"
  user_pool_id = aws_cognito_user_pool.this.id

  generate_secret = false # public client (SPA), uses Authorization Code + PKCE

  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_flows                  = ["code"]
  allowed_oauth_scopes                 = ["openid", "email", "profile"]

  supported_identity_providers = ["COGNITO"]

  callback_urls = var.callback_urls
  logout_urls   = var.logout_urls

  explicit_auth_flows = [
    "ALLOW_USER_SRP_AUTH",
    "ALLOW_REFRESH_TOKEN_AUTH",
    # Admin-auth lets test/CI scripts (and us, right now) get a real JWT via
    # `aws cognito-idp admin-initiate-auth` without implementing SRP's
    # crypto handshake by hand. The SPA itself still only ever uses SRP —
    # this doesn't weaken end-user auth, just makes the client also usable
    # for server-side/admin-initiated auth.
    "ALLOW_ADMIN_USER_PASSWORD_AUTH",
  ]

  access_token_validity  = 1
  id_token_validity      = 1
  refresh_token_validity = 30
  token_validity_units {
    access_token  = "hours"
    id_token      = "hours"
    refresh_token = "days"
  }

  prevent_user_existence_errors = "ENABLED"
}
