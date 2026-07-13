# =============================================================================
# Terraform version and provider version constraints
# =============================================================================
# Phase 0 — Scaffold only. No resources are managed by this file yet.
# See infra-aws-original branch for the original self-defined modules.
# =============================================================================

terraform {
  required_version = ">= 1.9"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}
