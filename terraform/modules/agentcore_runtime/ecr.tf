resource "aws_ecr_repository" "this" {
  name = "${var.name_prefix}-${var.agent_name}"

  image_scanning_configuration {
    scan_on_push = true
  }

  # Lets `terraform destroy` remove the repo even if it still holds images —
  # this module is expected to be stood up for a test and torn down after,
  # not left running indefinitely.
  force_delete = true

  tags = var.tags
}

# Expire untagged images quickly so storage cost doesn't creep up across
# repeated `docker build`/push cycles during development. Tagged images
# (what the runtime actually points at) are left alone.
resource "aws_ecr_lifecycle_policy" "expire_untagged" {
  repository = aws_ecr_repository.this.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged images after ${var.ecr_untagged_image_expiry_days} days"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = var.ecr_untagged_image_expiry_days
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}
