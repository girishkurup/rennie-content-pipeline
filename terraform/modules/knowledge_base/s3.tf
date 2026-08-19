resource "random_id" "bucket_suffix" {
  byte_length = 4
}

resource "aws_s3_bucket" "kb_source" {
  bucket = "${var.name_prefix}-kb-source-${random_id.bucket_suffix.hex}"
}

resource "aws_s3_bucket_versioning" "kb_source" {
  bucket = aws_s3_bucket.kb_source.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "kb_source" {
  bucket = aws_s3_bucket.kb_source.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "aws:kms"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "kb_source" {
  bucket                  = aws_s3_bucket.kb_source.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Placeholder Rennie/Bayer brand, legal, and compliance docs so the pipeline is
# testable end to end. Replace these with real content before any real use
# (see docs/kb-content-checklist.md).
resource "aws_s3_object" "sample_docs" {
  for_each = fileset("${path.module}/../../../kb-sample-content", "*.md")

  bucket = aws_s3_bucket.kb_source.id
  key    = each.value
  source = "${path.module}/../../../kb-sample-content/${each.value}"
  etag   = filemd5("${path.module}/../../../kb-sample-content/${each.value}")
}
