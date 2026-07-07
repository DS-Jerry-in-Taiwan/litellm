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
  description = "Existing Aurora cluster identifier"
  value       = data.aws_rds_cluster.existing.cluster_identifier
}

output "region" {
  description = "AWS region"
  value       = var.region
}
