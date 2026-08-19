terraform {
  required_version = ">= 1.9.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.51.0" # first version with aws_bedrockagentcore_agent_runtime support
    }
    archive = {
      source  = "hashicorp/archive"
      version = ">= 2.4.0"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.6.0"
    }
  }

  # Local backend for the initial build. Once you have a shared state bucket,
  # replace this with an S3 backend (bucket + dynamodb table for locking) and
  # run `terraform init -migrate-state`.
  #
  # backend "s3" {
  #   bucket         = "rennie-content-pipeline-tfstate"
  #   key            = "envs/dev/terraform.tfstate"
  #   region         = "us-east-1"
  #   dynamodb_table = "rennie-content-pipeline-tflock"
  #   encrypt        = true
  # }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "rennie-content-pipeline"
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}
