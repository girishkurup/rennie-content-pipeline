# Audit/export copy of every draft a job produces. DynamoDB (content_jobs)
# stays the primary store the app actually reads from — this bucket exists
# so a specific version can be downloaded/exported and so there's a
# permanent record even after DynamoDB item data is superseded by later
# revisions.

resource "aws_s3_bucket" "artifacts" {
  bucket = "${var.name_prefix}-content-artifacts"
  tags   = var.tags
}

resource "aws_s3_bucket_versioning" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "artifacts" {
  bucket                  = aws_s3_bucket.artifacts.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
