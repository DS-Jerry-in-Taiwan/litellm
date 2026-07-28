# =============================================================================
# ECR Repository — Phase 3: Terraform-managed ECR
# =============================================================================
# Creates a managed ECR repository when create_ecr_repository=true.
# Supports dual-mode: managed ECR or existing external ECR ARN.
# ECR URL / image URI are derived in main.tf locals.
# =============================================================================

resource "aws_ecr_repository" "litellm" {
  count                = var.create_ecr_repository ? 1 : 0
  name                 = var.ecr_repository_name
  image_tag_mutability = var.ecr_image_tag_mutability
  force_delete         = var.ecr_force_delete

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }

  tags = merge(local.common_tags, { Name = var.ecr_repository_name })
}
