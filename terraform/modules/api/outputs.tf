output "api_endpoint" {
  description = "Base invoke URL, e.g. https://abc123.execute-api.us-east-1.amazonaws.com"
  value       = aws_apigatewayv2_api.this.api_endpoint
}
