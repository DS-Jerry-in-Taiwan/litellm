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
# Phase 1: Secrets Manager + IAM
#   • aws_secretsmanager_secret.litellm_master_key     (secrets.tf)
#   • aws_secretsmanager_secret.litellm_database_url   (secrets.tf)
#   • aws_secretsmanager_secret.litellm_salt_key       (secrets.tf)
#   • aws_iam_role.ecs_execution + policy             (iam.tf)
#   • aws_iam_role.ecs_task + policy                  (iam.tf)
#   • aws_cloudwatch_log_group.ecs                    (cloudwatch.tf)
# ═════════════════════════════════════════════════════════════════════════════

# ═════════════════════════════════════════════════════════════════════════════
# Phase 2: ECS + ALB (to be added)
# ═════════════════════════════════════════════════════════════════════════════

# ═════════════════════════════════════════════════════════════════════════════
# Phase 3: S3 config + migration task (to be added)
# ═════════════════════════════════════════════════════════════════════════════

# ═════════════════════════════════════════════════════════════════════════════
# Phase 4-5: CI/CD hardening (to be added)
# ═════════════════════════════════════════════════════════════════════════════
