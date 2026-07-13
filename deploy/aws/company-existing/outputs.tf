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
