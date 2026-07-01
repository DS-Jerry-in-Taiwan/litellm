# =============================================================================
# ECR Module — Amazon Elastic Container Registry Repository
# =============================================================================

resource "aws_ecr_repository" "litellm" {
  name = var.repository_name
  # prd-like: prevent image tags from being overwritten after push.
  # Use 'MUTABLE' only for development quickstarts.
  # After setting to IMMUTABLE, you must use a new tag for each release
  # (e.g. docker tag .../litellm:v1.0.0 && docker push .../litellm:v1.0.0).
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }

  tags = merge(var.tags, { Name = "litellm-ecr-repo" })
}

# Lifecycle policy: keep last 5 versioned images, expire untagged after 14 days
resource "aws_ecr_lifecycle_policy" "main" {
  repository = aws_ecr_repository.litellm.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep last 5 versioned images (tags starting with 'v')"
        selection = {
          tagStatus     = "tagged"
          tagPrefixList = ["v"] # Covers v1, v2, v20260625-image-parity, etc.
          countType     = "imageCountMoreThan"
          countNumber   = 5
        }
        action = {
          type = "expire"
        }
      },
      {
        rulePriority = 2
        description  = "Expire untagged images older than 14 days"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countNumber = 14
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}