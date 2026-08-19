output "bucket_name" {
  value = aws_s3_bucket.frontend.bucket
}

output "cloudfront_domain_name" {
  description = "e.g. d123abc4defghi.cloudfront.net — the site's URL is https://<this>"
  value       = aws_cloudfront_distribution.frontend.domain_name
}

output "cloudfront_distribution_id" {
  description = "Needed to invalidate the cache after redeploying frontend/dist."
  value       = aws_cloudfront_distribution.frontend.id
}
