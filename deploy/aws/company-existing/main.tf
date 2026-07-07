# =============================================================================
# Company Existing AWS — LiteLLM ECS Fargate Deployment
# =============================================================================
# Phase 0 — Scaffold only.
#
# This file will be incrementally populated across Phases 1-5:
#   Phase 1: Secrets Manager + IAM skeleton
#   Phase 2: ECS Cluster + Task Definition + ALB + CloudWatch
#   Phase 3: S3 config + migration task
#   Phase 4-5: CI/CD hardening
#
# Design principles:
#   1. Do NOT manage existing company resources (VPC, Aurora, Subnets, SGs).
#   2. Use data sources (data_sources.tf) to read existing resources.
#   3. Only create LiteLLM runtime resources: ECS, ALB, IAM, Secrets, Logs.
#   4. Follow P0 safety baseline from the start.
# =============================================================================

locals {
  name_prefix = "litellm"
  common_tags = var.tags
}

# ═════════════════════════════════════════════════════════════════════════════
# Phase 1: Secrets Manager + IAM (to be added)
# ═════════════════════════════════════════════════════════════════════════════

# ═════════════════════════════════════════════════════════════════════════════
# Phase 2: ECS + ALB + CloudWatch (to be added)
# ═════════════════════════════════════════════════════════════════════════════

# ═════════════════════════════════════════════════════════════════════════════
# Phase 3: S3 config + migration task (to be added)
# ═════════════════════════════════════════════════════════════════════════════

# ═════════════════════════════════════════════════════════════════════════════
# Phase 4-5: CI/CD hardening (to be added)
# ═════════════════════════════════════════════════════════════════════════════
