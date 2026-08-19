locals {
  collection_name     = "${var.name_prefix}-kb"
  vector_index_name   = "bedrock-knowledge-base-default-index"
  vector_field_name   = "bedrock-knowledge-base-default-vector"
  text_field_name     = "AMAZON_BEDROCK_TEXT_CHUNK"
  metadata_field_name = "AMAZON_BEDROCK_METADATA"
}

resource "aws_opensearchserverless_security_policy" "encryption" {
  name = "${local.collection_name}-enc"
  type = "encryption"
  policy = jsonencode({
    Rules = [{
      ResourceType = "collection"
      Resource     = ["collection/${local.collection_name}"]
    }]
    AWSOwnedKey = true
  })
}

resource "aws_opensearchserverless_security_policy" "network" {
  name = "${local.collection_name}-net"
  type = "network"
  policy = jsonencode([{
    Rules = [{
      ResourceType = "collection"
      Resource     = ["collection/${local.collection_name}"]
    }]
    AllowFromPublic = true # data-plane calls come from the Bedrock KB service + our index-bootstrap script; access itself is still gated by the data access policy below
  }])
}

resource "aws_opensearchserverless_collection" "kb" {
  name = local.collection_name
  type = "VECTORSEARCH"

  # Cuts the minimum OCU-hour floor roughly in half for this dev/test
  # collection — no redundancy needed for a single one-off end-to-end test
  # that gets destroyed right after (see cost-control notes in memory).
  standby_replicas = "DISABLED"

  depends_on = [
    aws_opensearchserverless_security_policy.encryption,
    aws_opensearchserverless_security_policy.network,
  ]
}

resource "aws_opensearchserverless_access_policy" "data" {
  name = "${local.collection_name}-access"
  type = "data"
  policy = jsonencode([{
    Rules = [
      {
        ResourceType = "collection"
        Resource     = ["collection/${local.collection_name}"]
        Permission   = ["aoss:*"]
      },
      {
        ResourceType = "index"
        Resource     = ["index/${local.collection_name}/*"]
        Permission   = ["aoss:*"]
      }
    ]
    # The KB service role needs data-plane access at query/ingest time; the
    # Terraform caller identity needs it once, to bootstrap the vector index below.
    Principal = distinct(compact([
      aws_iam_role.kb_role.arn,
      data.aws_caller_identity.current.arn,
    ]))
  }])
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# OpenSearch Serverless indices are a data-plane construct with no native
# Terraform resource in the aws provider. We bootstrap it with a small,
# idempotent SigV4-signed script instead of adding the community `opensearch`
# provider (which would create a provider-config chicken/egg problem, since
# its config depends on the collection endpoint this same apply creates).
resource "time_sleep" "wait_for_collection" {
  depends_on      = [aws_opensearchserverless_access_policy.data]
  create_duration = "30s"
}

resource "null_resource" "create_vector_index" {
  depends_on = [time_sleep.wait_for_collection]

  triggers = {
    collection_endpoint = aws_opensearchserverless_collection.kb.collection_endpoint
    index_name          = local.vector_index_name
    dimensions          = var.embedding_dimensions
  }

  provisioner "local-exec" {
    interpreter = ["python3"]
    command     = "${path.module}/scripts/create_vector_index.py"
    environment = {
      COLLECTION_ENDPOINT = aws_opensearchserverless_collection.kb.collection_endpoint
      INDEX_NAME          = local.vector_index_name
      VECTOR_FIELD        = local.vector_field_name
      TEXT_FIELD          = local.text_field_name
      METADATA_FIELD      = local.metadata_field_name
      DIMENSIONS          = tostring(var.embedding_dimensions)
      AWS_REGION          = data.aws_region.current.region
    }
  }
}
