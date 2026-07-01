# =============================================================================
# Networking Module Outputs
# =============================================================================

output "vpc_id" {
  description = "ID of the VPC (created or existing)."
  value       = local.vpc_id
}

output "public_subnet_ids" {
  description = "IDs of the public subnets (created or existing)."
  value       = var.create_vpc ? aws_subnet.public[*].id : var.existing_public_subnet_ids
}

output "private_app_subnet_ids" {
  description = "IDs of the private app subnets (ECS tasks) (created or existing)."
  value       = var.create_vpc ? aws_subnet.private_app[*].id : var.existing_private_app_subnet_ids
}

output "private_data_subnet_ids" {
  description = "IDs of the private data subnets (RDS, ElastiCache) (created or existing)."
  value       = var.create_vpc ? aws_subnet.private_data[*].id : var.existing_private_data_subnet_ids
}

output "alb_security_group_id" {
  description = "Security group ID of the ALB (created or existing)."
  value       = var.create_vpc ? aws_security_group.alb[0].id : var.existing_vpc_alb_sg_id
}

output "ecs_security_group_id" {
  description = "Security group ID of the ECS tasks (created or existing)."
  value       = var.create_vpc ? aws_security_group.ecs[0].id : var.existing_vpc_ecs_sg_id
}

output "data_security_group_id" {
  description = "Security group ID of the data layer (RDS/Redis) (created or existing)."
  value       = var.create_vpc ? aws_security_group.data[0].id : var.existing_vpc_data_sg_id
}