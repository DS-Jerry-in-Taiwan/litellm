# =============================================================================
# Input Variables — AWS ECS Fargate Infrastructure Skeleton
# =============================================================================
# All values here are safe examples / placeholders.
# Real values must be provided via terraform.tfvars or environment variables.
# NEVER commit real secrets, account IDs, passwords, or API keys to Git.
# =============================================================================

# ─────────────────────────────────────────────────────────────────────────────
# AWS General
# ─────────────────────────────────────────────────────────────────────────────

variable "aws_region" {
  description = "AWS region for all resources."
  type        = string
  default     = "us-east-1"
}

variable "tags" {
  description = "Map of tags applied to all AWS resources."
  type        = map(string)
  default = {
    Project     = "LiteLLM"
    Environment = "production"
    ManagedBy   = "Terraform"
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# VPC / Networking
# ─────────────────────────────────────────────────────────────────────────────

variable "vpc_cidr" {
  description = <<-EOT
    CIDR block for the VPC (used only when create_vpc = true).
    - Production: use a private range, e.g. 10.0.0.0/16
    - When create_vpc = false: set existing_vpc_id instead; vpc_cidr is ignored
  EOT
  type        = string
  default     = "10.0.0.0/16"
}

variable "create_vpc" {
  description = "Whether to create a new VPC. Set to false to use an existing VPC via var.existing_vpc_id."
  type        = bool
  default     = true
}

variable "existing_vpc_id" {
  description = "Existing VPC ID when create_vpc = false. Must have private subnets and security groups pre-configured."
  type        = string
  default     = ""
}

variable "existing_public_subnet_ids" {
  description = <<-EOT
    IDs of existing public subnet(s) when create_vpc = false.
    Required: 2 subnets in different AZs for the ALB.
  EOT
  type        = list(string)
  default     = []
}

variable "existing_private_app_subnet_ids" {
  description = <<-EOT
    IDs of existing private app subnet(s) when create_vpc = false.
    ECS tasks run here. Must be in different AZs.
  EOT
  type        = list(string)
  default     = []
}

variable "existing_private_data_subnet_ids" {
  description = <<-EOT
    IDs of existing private data subnet(s) when create_vpc = false.
    RDS and ElastiCache run here. Must be in different AZs.
  EOT
  type        = list(string)
  default     = []
}

variable "existing_vpc_alb_sg_id" {
  description = <<-EOT
    Existing ALB security group ID when create_vpc = false.
    Must allow HTTPS 443 from internet and port 4000 to ECS SG.
  EOT
  type        = string
  default     = ""
}

variable "existing_vpc_ecs_sg_id" {
  description = <<-EOT
    Existing ECS tasks security group ID when create_vpc = false.
    Must allow port 4000 from ALB SG.
  EOT
  type        = string
  default     = ""
}

variable "existing_vpc_data_sg_id" {
  description = <<-EOT
    Existing data-layer security group ID (RDS/Redis) when create_vpc = false.
    Must allow ECS on PostgreSQL (5432) and Redis (6379).
  EOT
  type        = string
  default     = ""
}

variable "availability_zones" {
  description = "List of availability zones for the VPC. Must have at least 2 for HA."
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b"]
}

variable "public_subnet_cidrs" {
  description = "CIDR blocks for public subnets (one per AZ)."
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24"]
}

variable "private_app_subnet_cidrs" {
  description = "CIDR blocks for private app subnets (ECS tasks)."
  type        = list(string)
  default     = ["10.0.11.0/24", "10.0.12.0/24"]
}

variable "private_data_subnet_cidrs" {
  description = "CIDR blocks for private data subnets (RDS, ElastiCache)."
  type        = list(string)
  default     = ["10.0.21.0/24", "10.0.22.0/24"]
}

variable "enable_nat_gateway" {
  description = "Whether to create NAT Gateways for ECS outbound internet access. Disable if ECS needs no internet."
  type        = bool
  default     = true
}

# ─────────────────────────────────────────────────────────────────────────────
# ECR Repository
# ─────────────────────────────────────────────────────────────────────────────

variable "ecr_repository_name" {
  description = "Name of the ECR repository for the LiteLLM custom image."
  type        = string
  default     = "litellm-deployment-template"
}

variable "image_tag" {
  description = <<-EOT
    Immutable image tag (or full image digest) for the ECS task.
    REQUIRED: Must NOT be 'latest' in any prd-like environment.
    Use a pinned release tag (e.g. 'v20260625-image-parity') or an image
    digest (e.g. 'sha256:abc123def...') for full immutability.
    The Releaser is responsible for pinning this before ECS promotion.
  EOT
  type        = string
  default     = "latest" # Placeholder; MUST be overridden in terraform.tfvars with a real tag

  validation {
    condition     = var.image_tag != "latest"
    error_message = "image_tag must NOT be 'latest'. Override in terraform.tfvars with a pinned tag or digest (e.g. 'v20260625-image-parity')."
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# ECS Fargate
# ─────────────────────────────────────────────────────────────────────────────

variable "ecs_cluster_name" {
  description = "Name of the ECS cluster."
  type        = string
  default     = "litellm-cluster"
}

variable "ecs_desired_count" {
  description = <<-EOT
    Desired number of ECS task replicas.
    - Production: minimum 2 for HA.
    - Dev: can be set to 1.
  EOT
  type        = number
  default     = 2
}

variable "ecs_min_capacity" {
  description = "Minimum number of ECS tasks (autoscaling lower bound)."
  type        = number
  default     = 1
}

variable "ecs_max_capacity" {
  description = "Maximum number of ECS tasks (autoscaling upper bound)."
  type        = number
  default     = 4
}

# Fargate CPU/memory valid combos: 256 (0.25GB), 512 (1GB), 1024 (2GB),
# 2048 (4-8GB), 4096 (8-16GB). See: https://docs.aws.amazon.com/AmazonECS/
variable "ecs_task_cpu" {
  description = "Fargate task CPU units (256, 512, 1024, 2048, 4096)."
  type        = number
  default     = 1024
}

variable "ecs_task_memory" {
  description = "Fargate task memory in MB. Must be a valid combo with ecs_task_cpu."
  type        = number
  default     = 2048
}

variable "container_port" {
  description = "Container port that LiteLLM listens on (matches Dockerfile CMD)."
  type        = number
  default     = 4000
}

# ─────────────────────────────────────────────────────────────────────────────
# ALB
# ─────────────────────────────────────────────────────────────────────────────

variable "alb_name" {
  description = "Name of the Application Load Balancer."
  type        = string
  default     = "litellm-alb"
}

variable "alb_health_check_path" {
  description = "ALB target group health check path (LiteLLM /health/liveliness)."
  type        = string
  default     = "/health/liveliness"
}

variable "alb_health_check_matcher" {
  description = "Expected health check HTTP response code."
  type        = string
  default     = "200"
}

variable "acm_certificate_arn" {
  description = <<-EOT
    ACM certificate ARN for HTTPS listener.
    - Production: required (e.g. arn:aws:acm:us-east-1:<account-id>:certificate/<uuid>)
    - Dev/placeholder: leave as empty string to use HTTP only
  EOT
  type        = string
  default     = "" # Empty = HTTP-only placeholder; replace with real ACM cert for production
}

# ─────────────────────────────────────────────────────────────────────────────
# RDS PostgreSQL
# ─────────────────────────────────────────────────────────────────────────────

variable "rds_instance_class" {
  description = "RDS instance class (e.g. db.t3.micro for dev, db.r6g.large for prod)."
  type        = string
  default     = "db.t3.micro"
}

variable "rds_allocated_storage_gb" {
  description = "RDS allocated storage in GB."
  type        = number
  default     = 20
}

variable "rds_db_name" {
  description = "Name of the PostgreSQL database."
  type        = string
  default     = "litellm"
}

variable "rds_username" {
  description = "Master username for RDS. Store in Secrets Manager; do NOT hardcode."
  type        = string
  default     = "litellm_admin" # Placeholder; real value comes from Secrets Manager
}

# rds_password is NOT a variable — it must come from Secrets Manager.
# See data/main.tf for the Secrets Manager reference.

variable "rds_multi_az" {
  description = "Enable Multi-AZ for RDS (recommended for production)."
  type        = bool
  default     = false # Set to true for production
}

variable "rds_backup_retention_days" {
  description = "RDS automated backup retention period in days."
  type        = number
  default     = 1
}

# ─────────────────────────────────────────────────────────────────────────────
# ElastiCache Redis/Valkey
# ─────────────────────────────────────────────────────────────────────────────

variable "redis_node_type" {
  description = "ElastiCache node type (e.g. cache.t3.micro for dev, cache.r6g.medium for prod)."
  type        = string
  default     = "cache.t3.micro"
}

variable "redis_num_nodes" {
  description = "Number of ElastiCache nodes. Use 1 for single-AZ dev; 2+ for prod HA."
  type        = number
  default     = 1
}

variable "redis_port" {
  description = "Redis port (matches config.yaml / compose.yaml default)."
  type        = number
  default     = 6379
}

# redis_password is NOT a variable — it must come from Secrets Manager.
# See data/main.tf for the Secrets Manager reference.

# ─────────────────────────────────────────────────────────────────────────────
# Secrets Manager / SSM Parameter Store
# ─────────────────────────────────────────────────────────────────────────────

variable "secretsmanager_secret_name_litellm_master" {
  description = "Secrets Manager secret name for LITELLM_MASTER_KEY."
  type        = string
  default     = "litellm/litellm-master-key"
}

variable "secretsmanager_secret_name_db" {
  description = "Secrets Manager secret name for DATABASE_URL."
  type        = string
  default     = "litellm/database-url"
}

variable "secretsmanager_secret_name_redis" {
  description = "Secrets Manager secret name for REDIS_PASSWORD (empty string if no auth)."
  type        = string
  default     = "litellm/redis-password"
}

variable "secretsmanager_secret_name_salt" {
  description = "Secrets Manager secret name for LITELLM_SALT_KEY."
  type        = string
  default     = "litellm/litellm-salt-key"
}

variable "ssm_parameter_name_openai_key" {
  description = "SSM Parameter Store name for OPENAI_API_KEY (or provider key)."
  type        = string
  default     = "litellm/openai-api-key"
}

variable "create_ssm_parameter_openai_key" {
  description = <<-EOT
    Whether to create the SSM Parameter for OPENAI_API_KEY.
    Default (false): no placeholder SSM parameter is created; document-only.
    true: creates SSM parameter with no initial value; must be populated pre-deploy.
    See modules/data/main.tf for pre-deploy population instructions.
  EOT
  type        = bool
  default     = false
}

# ─────────────────────────────────────────────────────────────────────────────
# CloudWatch
# ─────────────────────────────────────────────────────────────────────────────

variable "cloudwatch_log_group_name" {
  description = "CloudWatch log group name for ECS container logs."
  type        = string
  default     = "/ecs/litellm"
}

variable "cloudwatch_log_retention_days" {
  description = "CloudWatch log retention period in days."
  type        = number
  default     = 14
}