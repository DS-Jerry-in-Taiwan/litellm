# =============================================================================
# AWS Provider Configuration
# =============================================================================
# Phase 0 — Scaffold only. No AWS resources are created.
# Credentials provided at plan/apply time via:
#   - AWS_PROFILE environment variable
#   - AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY
#   - EC2 instance role / ECS task role
# =============================================================================

provider "aws" {
  region = var.region

  default_tags {
    tags = var.tags
  }
}
