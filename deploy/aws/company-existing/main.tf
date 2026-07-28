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

  # ── ECR Image (Phase 3 dual-mode: managed ECR or existing external ARN) ──
  account_id = data.aws_caller_identity.current.account_id

  # ECR repository ARN: Terraform-managed or existing external
  ecr_repository_arn = var.create_ecr_repository ? aws_ecr_repository.litellm[0].arn : var.ecr_repository_arn

  # ECR repository URL: managed repo URL, or URL derived from existing ARN
  ecr_repository_url = var.create_ecr_repository ? aws_ecr_repository.litellm[0].repository_url : "${local.account_id}.dkr.ecr.${var.region}.amazonaws.com/${element(split("/", var.ecr_repository_arn), length(split("/", var.ecr_repository_arn)) - 1)}"

  # Full image URI for ECS task definition
  ecr_image = "${local.ecr_repository_url}:${var.image_tag}"

  # Backward-compatible alias (used by existing code paths)
  ecr_image_uri = local.ecr_repository_url

  # ── Bridge Layer — conditional resource flags ──
  deploy = {
    db_secret = var.existing_aurora_cluster_identifier != ""
  }
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
# Phase 2: ECS + ALB
#   • aws_security_group.alb                      (sg.tf)
#   • aws_security_group.ecs                      (sg.tf)
#   • aws_vpc_security_group_ingress_rule.ecs_from_alb   (sg.tf)
#   • aws_vpc_security_group_ingress_rule.alb_http      (sg.tf)
#   • aws_vpc_security_group_egress_rule.alb_to_ecs      (sg.tf)
#   • aws_vpc_security_group_egress_rule.ecs_to_data    (sg.tf)
#   • aws_lb.main                                 (alb.tf)
#   • aws_lb_target_group.litellm                (alb.tf)
#   • aws_lb_listener.http                       (alb.tf)
#   • aws_ecs_cluster.main                       (ecs.tf)
#   • aws_ecs_task_definition.litellm            (ecs.tf)
#   • aws_ecs_service.litellm                    (ecs.tf)
# ═════════════════════════════════════════════════════════════════════════════

# ═════════════════════════════════════════════════════════════════════════════
# Phase 3: S3 config + migration task
#   • data.aws_caller_identity.current               (data_sources.tf)
#   • aws_s3_bucket.config                         (s3.tf)
#   • aws_s3_bucket_versioning.config              (s3.tf)
#   • aws_s3_bucket_server_side_encryption_configuration.config  (s3.tf)
#   • aws_s3_bucket_public_access_block.config     (s3.tf)
#   • aws_s3_object.config                        (s3.tf)
#   • aws_ecs_task_definition.migration           (migration.tf)
#   • terraform_data.force_deploy                  (ecs.tf)
# ═════════════════════════════════════════════════════════════════════════════

# ═════════════════════════════════════════════════════════════════════════════
# Phase 4-5: CI/CD hardening
#   • aws_cloudwatch_metric_alarm.alb_5xx_high              (alarms.tf)
#   • aws_cloudwatch_metric_alarm.unhealthy_hosts           (alarms.tf)
#   • aws_cloudwatch_metric_alarm.ecs_cpu_high              (alarms.tf)
#   • aws_cloudwatch_metric_alarm.ecs_memory_high           (alarms.tf)
# ═════════════════════════════════════════════════════════════════════════════
