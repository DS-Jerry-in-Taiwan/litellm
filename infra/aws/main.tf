# =============================================================================
# Root Module — AWS ECS Fargate Infrastructure Skeleton
# =============================================================================
# Phase 2: IaC skeleton only. No terraform apply executed.
# =============================================================================

locals {
  common_tags = merge(
    var.tags,
    { Project = "LiteLLM" }
  )
}

# ─────────────────────────────────────────────────────────────────────────────
# Networking module — VPC, subnets, security groups, NAT Gateway
# ─────────────────────────────────────────────────────────────────────────────

module "networking" {
  source = "./modules/networking"

  create_vpc                       = var.create_vpc
  existing_vpc_id                  = var.existing_vpc_id
  existing_public_subnet_ids       = var.existing_public_subnet_ids
  existing_private_app_subnet_ids  = var.existing_private_app_subnet_ids
  existing_private_data_subnet_ids = var.existing_private_data_subnet_ids
  existing_vpc_alb_sg_id           = var.existing_vpc_alb_sg_id
  existing_vpc_ecs_sg_id           = var.existing_vpc_ecs_sg_id
  existing_vpc_data_sg_id          = var.existing_vpc_data_sg_id
  vpc_cidr                         = var.vpc_cidr
  availability_zones               = var.availability_zones
  public_subnet_cidrs              = var.public_subnet_cidrs
  private_app_subnet_cidrs         = var.private_app_subnet_cidrs
  private_data_subnet_cidrs        = var.private_data_subnet_cidrs
  enable_nat_gateway               = var.enable_nat_gateway
  tags                             = local.common_tags
}

# ─────────────────────────────────────────────────────────────────────────────
# Data layer module — RDS, ElastiCache, Secrets Manager, SSM, CloudWatch
# ─────────────────────────────────────────────────────────────────────────────

module "data" {
  source = "./modules/data"

  # Subnets
  private_data_subnet_ids = module.networking.private_data_subnet_ids

  # VPC + security groups (data SG from networking module)
  security_group_ids = [module.networking.data_security_group_id]

  # RDS
  rds_instance_class        = var.rds_instance_class
  rds_allocated_storage_gb  = var.rds_allocated_storage_gb
  rds_db_name               = var.rds_db_name
  rds_username              = var.rds_username
  rds_multi_az              = var.rds_multi_az
  rds_backup_retention_days = var.rds_backup_retention_days

  # ElastiCache
  redis_node_type = var.redis_node_type
  redis_num_nodes = var.redis_num_nodes
  redis_port      = var.redis_port

  # Secrets Manager names (ARNs derived by the module; actual values stay in AWS)
  secretsmanager_secret_name_litellm_master = var.secretsmanager_secret_name_litellm_master
  secretsmanager_secret_name_db             = var.secretsmanager_secret_name_db
  secretsmanager_secret_name_redis          = var.secretsmanager_secret_name_redis
  secretsmanager_secret_name_salt           = var.secretsmanager_secret_name_salt
  ssm_parameter_name_openai_key             = var.ssm_parameter_name_openai_key

  # SSM parameter creation (default off; prevents placeholder-as-secret)
  create_ssm_parameter_openai_key = var.create_ssm_parameter_openai_key

  # CloudWatch
  cloudwatch_log_group_name     = var.cloudwatch_log_group_name
  cloudwatch_log_retention_days = var.cloudwatch_log_retention_days

  tags = local.common_tags
}

# ─────────────────────────────────────────────────────────────────────────────
# ECR Repository
# ─────────────────────────────────────────────────────────────────────────────

module "ecr" {
  source = "./modules/ecr"

  repository_name = var.ecr_repository_name
  tags            = local.common_tags
}

# ─────────────────────────────────────────────────────────────────────────────
# ECS module — Cluster, Task Definition, Service, ALB, IAM
# ─────────────────────────────────────────────────────────────────────────────

module "ecs" {
  source = "./modules/ecs"

  # Region
  aws_region = var.aws_region

  # Subnets
  public_subnet_ids      = module.networking.public_subnet_ids
  private_app_subnet_ids = module.networking.private_app_subnet_ids

  # Security groups
  alb_security_group_id = module.networking.alb_security_group_id
  ecs_security_group_id = module.networking.ecs_security_group_id

  # VPC
  vpc_id = module.networking.vpc_id

  # ECR
  ecr_repository_url = module.ecr.repository_url
  image_tag          = var.image_tag

  # ECS
  ecs_cluster_name  = var.ecs_cluster_name
  ecs_desired_count = var.ecs_desired_count
  ecs_min_capacity  = var.ecs_min_capacity
  ecs_max_capacity  = var.ecs_max_capacity
  ecs_task_cpu      = var.ecs_task_cpu
  ecs_task_memory   = var.ecs_task_memory
  container_port    = var.container_port

  # ALB
  alb_name                 = var.alb_name
  alb_health_check_path    = var.alb_health_check_path
  alb_health_check_matcher = var.alb_health_check_matcher
  acm_certificate_arn      = var.acm_certificate_arn

  # Secrets (ARNs from data module; actual values in Secrets Manager)
  litellm_master_key_arn = module.data.litellm_master_key_arn
  database_url_arn       = module.data.database_url_arn
  redis_password_arn     = module.data.redis_password_arn
  litellm_salt_key_arn   = module.data.litellm_salt_key_arn
  openai_api_key_arn     = module.data.openai_api_key_arn

  # Redis endpoint (injected as ECS env var)
  redis_host = module.data.redis_endpoint
  redis_port = var.redis_port

  # CloudWatch
  cloudwatch_log_group_name = module.data.cloudwatch_log_group_name
  cloudwatch_log_group_arn  = module.data.cloudwatch_log_group_arn

  tags = local.common_tags
}