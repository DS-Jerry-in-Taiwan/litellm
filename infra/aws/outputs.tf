# =============================================================================
# Non-secret Terraform Outputs — AWS ECS Fargate Infrastructure Skeleton
# =============================================================================
# These outputs are safe to commit and display.
# No secrets, passwords, keys, or account IDs are exposed here.
# =============================================================================

output "aws_region" {
  description = "AWS region where resources are deployed."
  value       = var.aws_region
}

# ─────────────────────────────────────────────────────────────────────────────
# ECR
# ─────────────────────────────────────────────────────────────────────────────

output "ecr_repository_url" {
  description = "URL of the ECR repository for the LiteLLM custom image. Use for docker tag/push."
  value       = module.ecr.repository_url
}

output "ecr_repository_name" {
  description = "Name of the ECR repository."
  value       = module.ecr.repository_name
}

# ─────────────────────────────────────────────────────────────────────────────
# VPC / Networking
# ─────────────────────────────────────────────────────────────────────────────

output "vpc_id" {
  description = "ID of the VPC (created or existing)."
  value       = module.networking.vpc_id
}

output "private_app_subnet_ids" {
  description = "IDs of the private app subnets where ECS tasks run."
  value       = module.networking.private_app_subnet_ids
}

output "private_data_subnet_ids" {
  description = "IDs of the private data subnets where RDS and ElastiCache run."
  value       = module.networking.private_data_subnet_ids
}

output "alb_security_group_id" {
  description = "Security group ID of the ALB (for firewall rules)."
  value       = module.ecs.alb_security_group_id
}

output "ecs_security_group_id" {
  description = "Security group ID of the ECS tasks."
  value       = module.ecs.ecs_security_group_id
}

# ─────────────────────────────────────────────────────────────────────────────
# ECS
# ─────────────────────────────────────────────────────────────────────────────

output "ecs_cluster_name" {
  description = "Name of the ECS cluster."
  value       = module.ecs.ecs_cluster_name
}

output "ecs_cluster_arn" {
  description = "ARN of the ECS cluster."
  value       = module.ecs.ecs_cluster_arn
}

output "ecs_service_name" {
  description = "Name of the ECS service."
  value       = module.ecs.ecs_service_name
}

output "ecs_service_arn" {
  description = "ARN of the ECS service."
  value       = module.ecs.ecs_service_arn
}

output "ecs_task_definition_family" {
  description = "Family of the ECS task definition."
  value       = module.ecs.ecs_task_definition_family
}

# ─────────────────────────────────────────────────────────────────────────────
# ALB
# ─────────────────────────────────────────────────────────────────────────────

output "alb_dns_name" {
  description = <<-EOT
    DNS name of the Application Load Balancer.
    Use as LITELLM_BASE_URL in smoke tests after deployment:
      export LITELLM_BASE_URL="http://<alb_dns_name>"
    For HTTPS in production, use the ACM certificate-bound DNS name.
  EOT
  value       = module.ecs.alb_dns_name
}

output "alb_zone_id" {
  description = "Zone ID of the ALB (for Route53 alias records)."
  value       = module.ecs.alb_zone_id
}

output "alb_arn" {
  description = "ARN of the Application Load Balancer."
  value       = module.ecs.alb_arn
}

output "alb_listener_arn" {
  description = "ARN of the ALB HTTPS listener. Use with ACM certificate."
  value       = module.ecs.alb_https_listener_arn
}

# ─────────────────────────────────────────────────────────────────────────────
# RDS
# ─────────────────────────────────────────────────────────────────────────────

output "rds_endpoint" {
  description = "RDS PostgreSQL endpoint (for admin/debug only; use DATABASE_URL from Secrets Manager in app)."
  value       = module.data.rds_endpoint
}

output "rds_arn" {
  description = "ARN of the RDS instance."
  value       = module.data.rds_arn
}

# ─────────────────────────────────────────────────────────────────────────────
# ElastiCache
# ─────────────────────────────────────────────────────────────────────────────

output "redis_endpoint" {
  description = "ElastiCache Redis/Valkey endpoint (for admin/debug only; use REDIS_HOST from ECS env in app)."
  value       = module.data.redis_endpoint
}

output "redis_arn" {
  description = "ARN of the ElastiCache replication group."
  value       = module.data.redis_arn
}

# ─────────────────────────────────────────────────────────────────────────────
# CloudWatch
# ─────────────────────────────────────────────────────────────────────────────

output "cloudwatch_log_group_name" {
  description = "CloudWatch log group name for ECS container logs."
  value       = module.data.cloudwatch_log_group_name
}