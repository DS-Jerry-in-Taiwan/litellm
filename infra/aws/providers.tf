# =============================================================================
# AWS Provider Configuration
# =============================================================================
# NOTE: This skeleton does NOT run terraform apply.
#       Real credentials must be provided at plan/apply time via:
#       - AWS profile (AWS_PROFILE env var)
#       - AWS access keys (AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY env vars)
#       - EC2 instance role / ECS task role (auto-discovered by SDK)
#
# WARNING: Never commit real AWS access keys, secret keys, or account IDs.
#          Use terraform.tfvars for variable values, or environment variables.
# =============================================================================

provider "aws" {
  region = var.aws_region

  # Use default credentials chain:
  # 1. Environment variables (AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY)
  # 2. Shared config (~/.aws/config)
  # 3. Shared credentials (~/.aws/credentials)
  # 4. ECS task role / EC2 instance role
  default_tags {
    tags = var.tags
  }
}