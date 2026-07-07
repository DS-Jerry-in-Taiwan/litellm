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
  description = "ARN of the ECR repository containing the LiteLLM container image"
  type        = string
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

variable "acm_certificate_arn" {
  description = "ACM certificate ARN for HTTPS listener. Empty string = HTTP-only (requires allow_plaintext_alb=true)"
  type        = string
  default     = ""
}

variable "allow_plaintext_alb" {
  description = "Opt-in to HTTP-only ALB (requires explicit true when acm_certificate_arn is empty)"
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
