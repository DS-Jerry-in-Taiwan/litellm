# =============================================================================
# Networking Module Outputs
# =============================================================================

output "vpc_id" {
  description = "ID of the VPC (created or existing)."
  value       = local.vpc_id
}

output "public_subnet_ids" {
  description = "IDs of the public subnets. In provision mode, includes existing public subnets plus newly created ones. In new-VPC mode, all created subnets. In existing-VPC no-provision mode, existing subnets only."
  value = (
    local.provision_networking
    ? concat(var.existing_public_subnet_ids, aws_subnet.public[*].id)
    : var.existing_public_subnet_ids
  )
}

output "private_app_subnet_ids" {
  description = "IDs of the private app subnets (ECS tasks). In provision/create mode, newly created subnets. In existing-VPC no-provision mode, existing subnets."
  value = (
    local.provision_networking
    ? aws_subnet.private_app[*].id
    : var.existing_private_app_subnet_ids
  )
}

output "private_data_subnet_ids" {
  description = "IDs of the private data subnets (RDS, ElastiCache). In provision/create mode, newly created subnets. In existing-VPC no-provision mode, existing subnets."
  value = (
    local.provision_networking
    ? aws_subnet.private_data[*].id
    : var.existing_private_data_subnet_ids
  )
}

output "alb_security_group_id" {
  description = "Security group ID of the ALB. In provision/create mode, newly created SG. In existing-VPC no-provision mode, existing SG."
  value = (
    local.provision_networking
    ? aws_security_group.alb[0].id
    : var.existing_vpc_alb_sg_id
  )
}

output "ecs_security_group_id" {
  description = "Security group ID of the ECS tasks. In provision/create mode, newly created SG. In existing-VPC no-provision mode, existing SG."
  value = (
    local.provision_networking
    ? aws_security_group.ecs[0].id
    : var.existing_vpc_ecs_sg_id
  )
}

output "data_security_group_id" {
  description = "Security group ID of the data layer (RDS/Redis). In provision/create mode, newly created SG. In existing-VPC no-provision mode, existing SG."
  value = (
    local.provision_networking
    ? aws_security_group.data[0].id
    : var.existing_vpc_data_sg_id
  )
}

# =============================================================================
# VPC Endpoints (optional — only created when enable_vpc_endpoints = true)
# =============================================================================

output "vpc_endpoint_security_group_id" {
  description = "Security group ID for VPC Interface Endpoints. Empty when enable_vpc_endpoints = false."
  value       = var.enable_vpc_endpoints ? aws_security_group.vpc_endpoints[0].id : ""
}

output "vpc_endpoint_interface_ids" {
  description = "IDs of the VPC Interface Endpoints (ecr.api, ecr.dkr, secretsmanager, logs). Empty map when enable_vpc_endpoints = false."
  value       = var.enable_vpc_endpoints ? { for k, v in aws_vpc_endpoint.interface : k => v.id } : {}
}

output "vpc_endpoint_s3_id" {
  description = "ID of the S3 Gateway VPC Endpoint. Empty when enable_vpc_endpoints = false."
  value       = var.enable_vpc_endpoints ? aws_vpc_endpoint.s3[0].id : ""
}
