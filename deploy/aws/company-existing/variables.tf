# =============================================================================
# Input Variables — Company Existing AWS Infrastructure
# =============================================================================
# Phase 0 — Scaffold. These variables define the company's existing AWS
# resources that LiteLLM will be deployed alongside.
# =============================================================================

# ─────────────────────────────────────────────────────────────────────────────
# AWS General
# ─────────────────────────────────────────────────────────────────────────────

variable "region" {
  description = "AWS region (must match existing VPC/Aurora region)"
  type        = string
}

variable "tags" {
  description = "Common tags for all LiteLLM-created resources"
  type        = map(string)
  default = {
    Project     = "LiteLLM"
    Environment = "production"
    ManagedBy   = "Terraform"
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# Existing VPC
# ─────────────────────────────────────────────────────────────────────────────

variable "existing_vpc_id" {
  description = "ID of the existing datascienceResourceVPC"
  type        = string
}

variable "existing_private_app_subnet_ids" {
  description = "IDs of existing private app subnets (ECS tasks run here, need 2+ AZs)"
  type        = list(string)
}

variable "existing_private_data_subnet_ids" {
  description = "IDs of existing private data subnets (RDS/Redis, need 2+ AZs)"
  type        = list(string)
}

variable "existing_ecs_security_group_id" {
  description = "ID of existing security group for ECS tasks (port 4000 from ALB)"
  type        = string
  default     = "" # Will be created in Phase 3 if empty
}

variable "existing_data_security_group_id" {
  description = "ID of existing security group for RDS/Redis (5432/6379 from ECS)"
  type        = string
  default     = "" # Will be created in Phase 3 if empty
}

# ─────────────────────────────────────────────────────────────────────────────
# Existing Aurora PostgreSQL
# ─────────────────────────────────────────────────────────────────────────────

variable "existing_aurora_cluster_identifier" {
  description = "Identifier of the existing Aurora PostgreSQL cluster (aurora-postgre01)"
  type        = string
  default     = "aurora-postgre01"
}

variable "db_name" {
  description = "Database name for LiteLLM within the existing Aurora cluster"
  type        = string
  default     = "litellm"
}

# ─────────────────────────────────────────────────────────────────────────────
# LiteLLM ECS
# ─────────────────────────────────────────────────────────────────────────────

variable "image_tag" {
  description = "Immutable image tag or digest for the LiteLLM container. MUST NOT be 'latest'."
  type        = string

  validation {
    condition     = var.image_tag != "latest"
    error_message = "image_tag must NOT be 'latest'. Use a pinned version tag or digest."
  }
}

variable "ecr_repository_arn" {
  description = "Existing ECR repository ARN when create_ecr_repository=false. Leave empty when Terraform creates ECR."
  type        = string
  default     = ""

  validation {
    condition     = var.create_ecr_repository || var.ecr_repository_arn != ""
    error_message = "ecr_repository_arn is required when create_ecr_repository=false."
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# ECR Repository (Phase 3)
# ─────────────────────────────────────────────────────────────────────────────

variable "create_ecr_repository" {
  description = "Create and manage the LiteLLM ECR repository in this Terraform stack."
  type        = bool
  default     = false
}

variable "ecr_repository_name" {
  description = "ECR repository name when create_ecr_repository=true."
  type        = string
  default     = "litellm"
}

variable "ecr_image_tag_mutability" {
  description = "ECR tag mutability. Use IMMUTABLE for deployment safety."
  type        = string
  default     = "IMMUTABLE"

  validation {
    condition     = contains(["MUTABLE", "IMMUTABLE"], var.ecr_image_tag_mutability)
    error_message = "ecr_image_tag_mutability must be MUTABLE or IMMUTABLE."
  }
}

variable "ecr_force_delete" {
  description = "Allow deleting the ECR repository with images. Keep false outside disposable test envs."
  type        = bool
  default     = false
}

# ─────────────────────────────────────────────────────────────────────────────
# Redis / ElastiCache (Phase 3)
# ─────────────────────────────────────────────────────────────────────────────

variable "create_redis" {
  description = "Create ElastiCache Redis for LiteLLM shared cache/RPM counters."
  type        = bool
  default     = false
}

variable "redis_node_type" {
  description = "ElastiCache Redis node type."
  type        = string
  default     = "cache.t3.micro"
}

variable "redis_num_cache_clusters" {
  description = "Number of Redis cache nodes. Use 1 for office-mfa validation; >1 enables failover."
  type        = number
  default     = 1

  validation {
    condition     = var.redis_num_cache_clusters >= 1
    error_message = "redis_num_cache_clusters must be at least 1."
  }
}

variable "redis_port" {
  description = "Redis port."
  type        = number
  default     = 6379
}

variable "redis_auth_enabled" {
  description = "Future toggle for Redis AUTH token. Phase 3 keeps false to avoid secrets in Terraform state; remove/replace this validation in a future Secrets Manager AUTH phase."
  type        = bool
  default     = false

  validation {
    condition     = var.redis_auth_enabled == false
    error_message = "redis_auth_enabled is not implemented in Phase 3. Keep false to avoid secrets in Terraform state."
  }
}

variable "redis_host" {
  description = "Existing Redis host when create_redis=false. Empty means no external Redis."
  type        = string
  default     = ""
}

variable "container_port" {
  description = "Container port (LiteLLM proxy listens on 4000)"
  type        = number
  default     = 4000
}

variable "ecs_task_cpu" {
  description = "Fargate CPU units (256, 512, 1024, 2048, 4096)"
  type        = number
  default     = 1024
}

variable "ecs_task_memory" {
  description = "Fargate memory in MiB"
  type        = number
  default     = 2048
}

variable "ecs_desired_count" {
  description = "Desired number of ECS task replicas"
  type        = number
  default     = 2
}

variable "ecs_min_capacity" {
  description = "Min task count (autoscaling lower bound)"
  type        = number
  default     = 1
}

variable "ecs_max_capacity" {
  description = "Max task count (autoscaling upper bound)"
  type        = number
  default     = 4
}

# ─────────────────────────────────────────────────────────────────────────────
# ALB
# ─────────────────────────────────────────────────────────────────────────────

variable "alb_name" {
  description = "Name of the ALB"
  type        = string
  default     = "litellm-alb"
}

variable "alb_health_check_path" {
  description = "ALB target group health check path"
  type        = string
  default     = "/health/liveliness"
}

variable "alb_health_check_matcher" {
  description = "Expected health check HTTP response code"
  type        = string
  default     = "200"
}

variable "assign_public_ip" {
  description = "Assign public IP to ECS tasks. Set to true when using public subnets without NAT Gateway."
  type        = bool
  default     = false
}

variable "acm_certificate_arn" {
  description = "ACM certificate ARN for HTTPS listener. Empty string = HTTP-only (requires allow_plaintext_alb=true)"
  type        = string
  default     = ""
}

variable "allow_plaintext_alb" {
  description = "Opt-in to HTTP-only ALB. MUST be false for production. Set true for dev testing without ACM."
  type        = bool
  default     = false
}

# ─────────────────────────────────────────────────────────────────────────────
# Security / Destroy Guards
# ─────────────────────────────────────────────────────────────────────────────

variable "skip_final_snapshot" {
  description = "Skip final snapshot on RDS destroy (false for production)"
  type        = bool
  default     = false
}

variable "s3_force_destroy" {
  description = "Allow destroy to delete S3 bucket with objects (false for production)"
  type        = bool
  default     = false
}

# ─────────────────────────────────────────────────────────────────────────────
# LiteLLM Config (Phase 3+)
# ─────────────────────────────────────────────────────────────────────────────

variable "proxy_config_source" {
  description = "Local path to the LiteLLM proxy config.yaml. Empty string means use baked-in config."
  type        = string
  default     = ""
}

variable "proxy_config" {
  description = "LiteLLM proxy configuration (YAML map). Uploaded to S3 in Phase 3."
  type        = any
  default     = {}
}

# ─────────────────────────────────────────────────────────────────────────────
# LiteLLM Secrets (Phase 1+)
# ─────────────────────────────────────────────────────────────────────────────

variable "litellm_master_key" {
  description = "LiteLLM master key. Will be stored in AWS Secrets Manager."
  type        = string
  sensitive   = true
}

variable "litellm_salt_key" {
  description = "LiteLLM salt key. Will be stored in AWS Secrets Manager."
  type        = string
  sensitive   = true
}

# ─────────────────────────────────────────────────────────────────────────────
# LiteLLM Admin UI (Runtime Fix)
# ─────────────────────────────────────────────────────────────────────────────

variable "ui_username" {
  description = "LiteLLM Admin UI username. office-mfa dev default is admin."
  type        = string
  default     = "admin"
}

variable "ui_password" {
  description = "LiteLLM Admin UI password. office-mfa dev default is admin; production must override."
  type        = string
  sensitive   = true
  default     = "admin"
}

# ─────────────────────────────────────────────────────────────────────────────
# LiteLLM Runtime Env (Store Model in DB)
# ─────────────────────────────────────────────────────────────────────────────

variable "store_model_in_db" {
  description = "Set STORE_MODEL_IN_DB env var for LiteLLM ECS container. 'True' enables Admin UI Add Model feature."
  type        = string
  default     = "True"

  validation {
    condition     = contains(["True", "False"], var.store_model_in_db)
    error_message = "store_model_in_db must be 'True' or 'False'."
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# ECS Deployment Circuit Breaker (P1 Hardening)
# ─────────────────────────────────────────────────────────────────────────────

variable "ecs_deployment_circuit_breaker_enable" {
  description = "Enable ECS deployment circuit breaker."
  type        = bool
  default     = true
}

variable "ecs_deployment_circuit_breaker_rollback" {
  description = "Rollback failed ECS deployments automatically."
  type        = bool
  default     = true
}
