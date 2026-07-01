# =============================================================================
# Data Module Variables
# =============================================================================

variable "private_data_subnet_ids" {
  description = "IDs of the private data subnets for RDS and ElastiCache."
  type        = list(string)
}

variable "security_group_ids" {
  description = "Security group IDs for RDS and ElastiCache."
  type        = list(string)
}

# ── RDS ──────────────────────────────────────────────────────────────────────

variable "rds_instance_class" {
  description = "RDS instance class."
  type        = string
  default     = "db.t3.micro"
}

variable "rds_allocated_storage_gb" {
  description = "RDS allocated storage in GB."
  type        = number
  default     = 20
}

variable "rds_db_name" {
  description = "PostgreSQL database name."
  type        = string
  default     = "litellm"
}

variable "rds_username" {
  description = "RDS master username."
  type        = string
  default     = "litellm_admin"
}

variable "rds_multi_az" {
  description = "Enable Multi-AZ for RDS."
  type        = bool
  default     = false
}

variable "rds_backup_retention_days" {
  description = "RDS backup retention period in days."
  type        = number
  default     = 1
}

# ── ElastiCache ───────────────────────────────────────────────────────────────

variable "redis_node_type" {
  description = "ElastiCache node type."
  type        = string
  default     = "cache.t3.micro"
}

variable "redis_num_nodes" {
  description = "Number of ElastiCache nodes."
  type        = number
  default     = 1
}

variable "redis_port" {
  description = "Redis port."
  type        = number
  default     = 6379
}

# ── Secrets Manager / SSM ──────────────────────────────────────────────────────

variable "secretsmanager_secret_name_litellm_master" {
  description = "Secrets Manager secret name for LITELLM_MASTER_KEY."
  type        = string
  default     = "litellm/litellm-master-key"
}

variable "create_ssm_parameter_openai_key" {
  description = <<-EOT
    Whether to create the SSM Parameter for OPENAI_API_KEY.
    When false: only the SSM parameter name/ARN output is created (documented pre-deploy action).
    When true: creates the SSM parameter with no initial value (must be populated before ECS use).
    Recommended: false for prd-like; true for dev-only quickstarts.
    IMPORTANT: If true, the SSM parameter is created with NO initial value.
    The real provider key MUST be populated via AWS CLI/Console BEFORE ECS task starts:
      aws ssm put-parameter --name "litellm/openai-api-key" \\
        --value "sk-real-key" --type SecureString --overwrite
    Never let 'REPLACE_ME_IN_AWS_SSM' or any placeholder become an ECS runtime secret.
  EOT
  type        = bool
  default     = false
}

variable "secretsmanager_secret_name_db" {
  description = "Secrets Manager secret name for DATABASE_URL."
  type        = string
  default     = "litellm/database-url"
}

variable "secretsmanager_secret_name_redis" {
  description = "Secrets Manager secret name for REDIS_PASSWORD."
  type        = string
  default     = "litellm/redis-password"
}

variable "secretsmanager_secret_name_salt" {
  description = "Secrets Manager secret name for LITELLM_SALT_KEY."
  type        = string
  default     = "litellm/litellm-salt-key"
}

variable "ssm_parameter_name_openai_key" {
  description = "SSM Parameter Store name for OPENAI_API_KEY."
  type        = string
  default     = "litellm/openai-api-key"
}

# ── CloudWatch ────────────────────────────────────────────────────────────────

variable "cloudwatch_log_group_name" {
  description = "CloudWatch log group name for ECS logs."
  type        = string
  default     = "/ecs/litellm"
}

variable "cloudwatch_log_retention_days" {
  description = "CloudWatch log retention period in days."
  type        = number
  default     = 14
}

# ── Tags ──────────────────────────────────────────────────────────────────────

variable "tags" {
  description = "Tags to apply to all resources."
  type        = map(string)
  default     = {}
}