resource "aws_bedrockagent_knowledge_base" "rennie" {
  name     = "${var.name_prefix}-kb"
  role_arn = aws_iam_role.kb_role.arn

  knowledge_base_configuration {
    type = "VECTOR"
    vector_knowledge_base_configuration {
      embedding_model_arn = "arn:aws:bedrock:${data.aws_region.current.region}::foundation-model/${var.embedding_model_id}"
      embedding_model_configuration {
        bedrock_embedding_model_configuration {
          dimensions          = var.embedding_dimensions
          embedding_data_type = "FLOAT32"
        }
      }
    }
  }

  storage_configuration {
    type = "OPENSEARCH_SERVERLESS"
    opensearch_serverless_configuration {
      collection_arn    = aws_opensearchserverless_collection.kb.arn
      vector_index_name = local.vector_index_name
      field_mapping {
        vector_field   = local.vector_field_name
        text_field     = local.text_field_name
        metadata_field = local.metadata_field_name
      }
    }
  }

  depends_on = [null_resource.create_vector_index]
}

resource "aws_bedrockagent_data_source" "rennie_docs" {
  knowledge_base_id = aws_bedrockagent_knowledge_base.rennie.id
  name              = "${var.name_prefix}-brand-legal-compliance-docs"

  data_source_configuration {
    type = "S3"
    s3_configuration {
      bucket_arn = aws_s3_bucket.kb_source.arn
    }
  }

  vector_ingestion_configuration {
    chunking_configuration {
      chunking_strategy = "FIXED_SIZE"
      fixed_size_chunking_configuration {
        max_tokens         = var.chunk_max_tokens
        overlap_percentage = var.chunk_overlap_percentage
      }
    }
  }
}
