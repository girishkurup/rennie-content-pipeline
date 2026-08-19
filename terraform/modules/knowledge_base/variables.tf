variable "name_prefix" {
  description = "Prefix applied to the bucket, collection, and knowledge base names."
  type        = string
}

variable "embedding_model_id" {
  description = "Bedrock embedding model id, e.g. amazon.titan-embed-text-v2:0."
  type        = string
}

variable "embedding_dimensions" {
  description = "Output vector dimension of the embedding model. Must match the model's actual output size."
  type        = number
  default     = 1024
}

variable "chunk_max_tokens" {
  description = "Max tokens per chunk. Kept small on purpose so each retrieved chunk maps to roughly a sentence or two, which is what makes sentence-level citation practical."
  type        = number
  default     = 300
}

variable "chunk_overlap_percentage" {
  description = "Overlap between adjacent chunks, as a percentage."
  type        = number
  default     = 20
}
