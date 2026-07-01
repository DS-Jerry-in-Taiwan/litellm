# =============================================================================
# ECS Module Variables
# =============================================================================

variable "aws_region" {
  description = "AWS region (needed for CloudWatch log stream prefix)."
  type        = string
  default     = "us-east-1"
}

# ── Networking ────────────────────────────────────────────────────────────────

variable "public_subnet_ids" {
  description = "IDs of the public subnets for the ALB."
  type        = list(string)
}

variable "private_app_subnet_ids" {
  description = "IDs of the private app subnets for ECS tasks."
  type        = list(string)
}

variable "alb_security_group_id" {
  description = "Security group ID of the ALB."
  type        = string
}

variable "ecs_security_group_id" {
  description = "Security group ID of the ECS tasks."
  type        = string
}

variable "vpc_id" {
  description = "VPC ID."
  type        = string
}

# ── ECR ───────────────────────────────────────────────────────────────────────

variable "ecr_repository_url" {
  description = "ECR repository URL for the LiteLLM image."
  type        = string
}

variable "image_tag" {
  description = <<-EOT
    Immutable image tag (or full image digest) for the ECS task definition.
    Must NOT be 'latest' in any prd-like environment.
    Use a pinned tag (e.g. 'v20260625-image-parity') or an image digest
    (e.g. 'sha256:abc123...') for production deployments.
    Prd-like promotion requires the Releaser to pin a stable tag/digest
    before the ECS task definition is updated.
  EOT
  type        = string
}

# ── ECS ───────────────────────────────────────────────────────────────────────

variable "ecs_cluster_name" {
  description = "Name of the ECS cluster."
  type        = string
}

variable "ecs_desired_count" {
  description = "Desired number of ECS task replicas."
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

variable "ecs_task_cpu" {
  description = "Fargate task CPU units."
  type        = number
  default     = 1024
}

variable "ecs_task_memory" {
  description = "Fargate task memory in MB."
  type        = number
  default     = 2048
}

variable "container_port" {
  description = "Container port that LiteLLM listens on."
  type        = number
  default     = 4000
}

# ── ALB ───────────────────────────────────────────────────────────────────────

variable "alb_name" {
  description = "Name of the ALB."
  type        = string
}

variable "alb_health_check_path" {
  description = "ALB health check path."
  type        = string
  default     = "/health/liveliness"
}

variable "alb_health_check_matcher" {
  description = "Expected health check HTTP response code."
  type        = string
  default     = "200"
}

variable "acm_certificate_arn" {
  description = "ACM certificate ARN for HTTPS. Empty string = HTTP-only dev mode."
  type        = string
  default     = ""
}

# ── Secrets / Env ─────────────────────────────────────────────────────────────

variable "litellm_master_key_arn" {
  description = "ARN of the LITELLM_MASTER_KEY Secrets Manager secret."
  type        = string
}

variable "database_url_arn" {
  description = "ARN of the DATABASE_URL Secrets Manager secret."
  type        = string
}

variable "redis_password_arn" {
  description = "ARN of the REDIS_PASSWORD Secrets Manager secret."
  type        = string
}

variable "litellm_salt_key_arn" {
  description = "ARN of the LITELLM_SALT_KEY Secrets Manager secret."
  type        = string
}

variable "openai_api_key_arn" {
  description = "ARN of the OPENAI_API_KEY SSM parameter."
  type        = string
}

variable "redis_host" {
  description = "ElastiCache Redis endpoint (used as REDIS_HOST env var)."
  type        = string
}

variable "redis_port" {
  description = "Redis port (used as REDIS_PORT env var)."
  type        = number
  default     = 6379
}

# ── CloudWatch ────────────────────────────────────────────────────────────────

variable "cloudwatch_log_group_name" {
  description = "CloudWatch log group name for ECS container logs."
  type        = string
}

variable "cloudwatch_log_group_arn" {
  description = "ARN of the CloudWatch log group."
  type        = string
  default     = "" # Will be computed if empty
}

# ── Tags ──────────────────────────────────────────────────────────────────────

variable "tags" {
  description = "Tags to apply to all resources."
  type        = map(string)
  default     = {}
}