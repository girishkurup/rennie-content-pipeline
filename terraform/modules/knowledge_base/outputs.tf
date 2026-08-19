output "knowledge_base_id" {
  value = aws_bedrockagent_knowledge_base.rennie.id
}

output "knowledge_base_arn" {
  value = aws_bedrockagent_knowledge_base.rennie.arn
}

output "data_source_id" {
  value = aws_bedrockagent_data_source.rennie_docs.data_source_id
}

output "source_bucket_name" {
  value = aws_s3_bucket.kb_source.bucket
}

output "collection_arn" {
  value = aws_opensearchserverless_collection.kb.arn
}
