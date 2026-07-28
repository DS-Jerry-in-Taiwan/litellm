# =============================================================================
# Terraform Outputs — LiteLLM on Company Existing AWS
# =============================================================================
# Phase 0 — Scaffold. Outputs will be populated as resources are added.
# No secrets, passwords, keys, or account IDs are exposed here.
# =============================================================================

output "vpc_id" {
  description = "Existing VPC ID (datascienceResourceVPC)"
  value       = data.aws_vpc.existing.id
}

output "aurora_cluster_identifier" {
  description = "Existing Aurora cluster identifier (null if not configured)"
  value       = try(one(data.aws_rds_cluster.existing[*].cluster_identifier), null)
}

output "region" {
  description = "AWS region"
  value       = var.region
}

output "ecs_cluster_name" {
  description = "ECS cluster name for deployment workflows"
  value       = aws_ecs_cluster.main.name
}

output "ecs_service_name" {
  description = "ECS service name for deployment workflows"
  value       = aws_ecs_service.litellm.name
}

output "alb_dns_name" {
  description = "ALB DNS name for smoke tests"
  value       = aws_lb.main.dns_name
}

# =============================================================================
# ECR Outputs (Phase 3)
# =============================================================================

output "ecr_repository_arn" {
  description = "ECR repository ARN used by ECS (managed or existing)"
  value       = local.ecr_repository_arn
}

output "ecr_repository_url" {
  description = "ECR repository URL for docker push"
  value       = local.ecr_repository_url
}

# =============================================================================
# Redis / ElastiCache Outputs (Phase 3)
# =============================================================================

output "redis_endpoint" {
  description = "ElastiCache Redis endpoint used by LiteLLM (managed or external)"
  value       = var.create_redis ? aws_elasticache_replication_group.redis[0].primary_endpoint_address : var.redis_host
}

output "redis_port" {
  description = "Redis port used by LiteLLM"
  value       = var.redis_port
}
