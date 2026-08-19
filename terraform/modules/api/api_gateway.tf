# HTTP API (not REST API) — cheaper, simpler, and JWT authorizers are a
# first-class feature, matching a Cognito SPA client with no need for a
# Lambda authorizer of our own.

resource "aws_apigatewayv2_api" "this" {
  name          = "${var.name_prefix}-api"
  protocol_type = "HTTP"

  cors_configuration {
    allow_origins = var.allowed_cors_origins
    allow_methods = ["GET", "POST", "OPTIONS"]
    allow_headers = ["Authorization", "Content-Type"]
    max_age       = 300
  }

  tags = var.tags
}

resource "aws_apigatewayv2_authorizer" "cognito" {
  api_id           = aws_apigatewayv2_api.this.id
  authorizer_type  = "JWT"
  identity_sources = ["$request.header.Authorization"]
  name             = "${var.name_prefix}-cognito-authorizer"

  jwt_configuration {
    audience = [var.cognito_app_client_id]
    issuer   = "https://cognito-idp.${var.aws_region}.amazonaws.com/${var.cognito_user_pool_id}"
  }
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.this.id
  name        = "$default"
  auto_deploy = true

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.api_access.arn
    format = jsonencode({
      requestId      = "$context.requestId"
      routeKey       = "$context.routeKey"
      status         = "$context.status"
      integrationErr = "$context.integrationErrorMessage"
      responseLength = "$context.responseLength"
    })
  }

  tags = var.tags
}

resource "aws_cloudwatch_log_group" "api_access" {
  name              = "/aws/apigateway/${var.name_prefix}-api"
  retention_in_days = var.log_retention_days
  tags              = var.tags
}

# ---------------------------------------------------------------------------
# Integrations (one per lambda — HTTP APIs use lambda proxy integration)
# ---------------------------------------------------------------------------

resource "aws_apigatewayv2_integration" "chat_handler" {
  api_id                 = aws_apigatewayv2_api.this.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.chat_handler.invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_integration" "history_handler" {
  api_id                 = aws_apigatewayv2_api.this.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.history_handler.invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_integration" "review_handler" {
  api_id                 = aws_apigatewayv2_api.this.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.review_handler.invoke_arn
  payload_format_version = "2.0"
}

# ---------------------------------------------------------------------------
# Routes — every one requires a valid Cognito JWT; group-level checks
# (reviewers vs requesters) happen inside the lambdas themselves (they read
# the cognito:groups claim), not here.
# ---------------------------------------------------------------------------

resource "aws_apigatewayv2_route" "post_chat" {
  api_id             = aws_apigatewayv2_api.this.id
  route_key          = "POST /chat"
  target             = "integrations/${aws_apigatewayv2_integration.chat_handler.id}"
  authorization_type = "JWT"
  authorizer_id      = aws_apigatewayv2_authorizer.cognito.id
}

resource "aws_apigatewayv2_route" "get_conversations" {
  api_id             = aws_apigatewayv2_api.this.id
  route_key          = "GET /conversations"
  target             = "integrations/${aws_apigatewayv2_integration.history_handler.id}"
  authorization_type = "JWT"
  authorizer_id      = aws_apigatewayv2_authorizer.cognito.id
}

resource "aws_apigatewayv2_route" "get_conversation_messages" {
  api_id             = aws_apigatewayv2_api.this.id
  route_key          = "GET /conversations/{conversation_id}/messages"
  target             = "integrations/${aws_apigatewayv2_integration.history_handler.id}"
  authorization_type = "JWT"
  authorizer_id      = aws_apigatewayv2_authorizer.cognito.id
}

resource "aws_apigatewayv2_route" "get_jobs" {
  api_id             = aws_apigatewayv2_api.this.id
  route_key          = "GET /jobs"
  target             = "integrations/${aws_apigatewayv2_integration.history_handler.id}"
  authorization_type = "JWT"
  authorizer_id      = aws_apigatewayv2_authorizer.cognito.id
}

resource "aws_apigatewayv2_route" "get_job" {
  api_id             = aws_apigatewayv2_api.this.id
  route_key          = "GET /jobs/{job_id}"
  target             = "integrations/${aws_apigatewayv2_integration.history_handler.id}"
  authorization_type = "JWT"
  authorizer_id      = aws_apigatewayv2_authorizer.cognito.id
}

resource "aws_apigatewayv2_route" "post_job_review" {
  api_id             = aws_apigatewayv2_api.this.id
  route_key          = "POST /jobs/{job_id}/review"
  target             = "integrations/${aws_apigatewayv2_integration.review_handler.id}"
  authorization_type = "JWT"
  authorizer_id      = aws_apigatewayv2_authorizer.cognito.id
}

resource "aws_apigatewayv2_route" "post_job_stop" {
  api_id             = aws_apigatewayv2_api.this.id
  route_key          = "POST /jobs/{job_id}/stop"
  target             = "integrations/${aws_apigatewayv2_integration.review_handler.id}"
  authorization_type = "JWT"
  authorizer_id      = aws_apigatewayv2_authorizer.cognito.id
}

resource "aws_apigatewayv2_route" "get_job_artifact" {
  api_id             = aws_apigatewayv2_api.this.id
  route_key          = "GET /jobs/{job_id}/artifacts/{stage}"
  target             = "integrations/${aws_apigatewayv2_integration.history_handler.id}"
  authorization_type = "JWT"
  authorizer_id      = aws_apigatewayv2_authorizer.cognito.id
}

# ---------------------------------------------------------------------------
# Lambda permissions — let API Gateway actually invoke each function
# ---------------------------------------------------------------------------

resource "aws_lambda_permission" "chat_handler" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.chat_handler.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.this.execution_arn}/*/*"
}

resource "aws_lambda_permission" "history_handler" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.history_handler.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.this.execution_arn}/*/*"
}

resource "aws_lambda_permission" "review_handler" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.review_handler.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.this.execution_arn}/*/*"
}
