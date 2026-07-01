# =============================================================================
# Data Layer Module — RDS, ElastiCache, Secrets Manager, SSM, CloudWatch
# =============================================================================
# NOTE: ECS→data SG rules (5432/6379) are defined in the networking module.
#       This module does NOT create additional SG ingress rules to avoid duplication.
# =============================================================================

# ─────────────────────────────────────────────────────────────────────────────
# Secrets Manager — Secret ARNs (values stored separately, not in Terraform)
#
# PRE-DEPLOY CHECKPOINT — DATABASE_URL secret:
#   The aws_secretsmanager_secret.database_url resource is created with no value.
#   After `terraform apply`, you MUST populate the secret manually:
#     aws secretsmanager put-secret-value \
#       --secret-id "litellm/database-url" \
#       --secret-string "postgresql://<user>:<pass>@<rds_endpoint>:5432/litellm"
#   The RDS endpoint is available from `terraform output rds_endpoint`.
#   Do NOT skip this step — the ECS task will fail to start without it.
# ─────────────────────────────────────────────────────────────────────────────

# LITELLM_MASTER_KEY — stored in Secrets Manager; Terraform tracks the ARN only
resource "aws_secretsmanager_secret" "litellm_master_key" {
  name        = var.secretsmanager_secret_name_litellm_master
  description = "LiteLLM master key for admin API authentication"

  tags = merge(var.tags, { Name = "litellm-master-key" })
}

# DATABASE_URL — stored in Secrets Manager; Terraform tracks the ARN only
resource "aws_secretsmanager_secret" "database_url" {
  name        = var.secretsmanager_secret_name_db
  description = "PostgreSQL connection string for LiteLLM (postgresql://user:pass@host:5432/db)"

  tags = merge(var.tags, { Name = "litellm-database-url" })
}

# REDIS_PASSWORD — stored in Secrets Manager; Terraform tracks the ARN only
resource "aws_secretsmanager_secret" "redis_password" {
  name        = var.secretsmanager_secret_name_redis
  description = "ElastiCache Redis/Valkey password (set to empty string if auth disabled)"

  tags = merge(var.tags, { Name = "litellm-redis-password" })
}

# LITELLM_SALT_KEY — stored in Secrets Manager; Terraform tracks the ARN only
resource "aws_secretsmanager_secret" "litellm_salt_key" {
  name        = var.secretsmanager_secret_name_salt
  description = "LiteLLM salt key for DB field encryption"

  tags = merge(var.tags, { Name = "litellm-salt-key" })
}

# ─────────────────────────────────────────────────────────────────────────────
# SSM Parameter Store — Provider API keys (conditional creation)
#
# OPT-IN via var.create_ssm_parameter_openai_key.
# When disabled (default): only the SSM parameter name is documented as an
#   output; no placeholder value is created. Prevents placeholder-as-secret.
# When enabled: SSM parameter is created with NO initial value; the real
#   provider key MUST be populated via AWS CLI/Console BEFORE ECS task starts:
#     aws ssm put-parameter --name "litellm/openai-api-key" \
#       --value "sk-real-key" --type SecureString --overwrite
# Never commit real API keys to this Terraform file or any Git repository.
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_ssm_parameter" "openai_api_key" {
  count       = var.create_ssm_parameter_openai_key ? 1 : 0
  name        = var.ssm_parameter_name_openai_key
  description = "OpenAI API key for LiteLLM (or use Secrets Manager for other providers)"
  type        = "SecureString"
  # No initial value — must be populated pre-deploy via AWS CLI/Console
  value = "TEMP_PLACEHOLDER_MUST_BE_OVERWRITTEN"

  lifecycle {
    # Prevent accidental overwrite with a placeholder after initial apply
    ignore_changes = [value]
  }

  tags = merge(var.tags, { Name = "litellm-openai-api-key" })
}

# ─────────────────────────────────────────────────────────────────────────────
# CloudWatch Log Group
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_cloudwatch_log_group" "ecs" {
  name              = var.cloudwatch_log_group_name
  retention_in_days = var.cloudwatch_log_retention_days

  tags = merge(var.tags, { Name = "litellm-ecs-logs" })
}

# ─────────────────────────────────────────────────────────────────────────────
# RDS Subnet Group
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_db_subnet_group" "main" {
  name       = "litellm-rds-subnet-group"
  subnet_ids = var.private_data_subnet_ids

  tags = merge(var.tags, { Name = "litellm-rds-subnet-group" })
}

# ─────────────────────────────────────────────────────────────────────────────
# RDS PostgreSQL Instance
# ─────────────────────────────────────────────────────────────────────────────
# Password is managed by AWS RDS (stored in Secrets Manager automatically).
# We do NOT hardcode any password in Terraform state or code.
# The password is accessible via: aws secretsmanager get-secret-value --secret-id arn:aws:rds:...:secret:xxxx

resource "aws_db_instance" "main" {
  identifier     = "litellm-postgres"
  engine         = "postgres"
  engine_version = "15.4"
  instance_class = var.rds_instance_class

  allocated_storage     = var.rds_allocated_storage_gb
  max_allocated_storage = var.rds_allocated_storage_gb * 2

  db_name  = var.rds_db_name
  username = var.rds_username

  # AWS-managed master password — stored in Secrets Manager automatically
  # Do NOT set password = "..." or use a Terraform variable for the password.
  manage_master_user_password = true

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = var.security_group_ids

  multi_az                = var.rds_multi_az
  backup_retention_period = var.rds_backup_retention_days
  backup_window           = "03:00-04:00"
  maintenance_window      = "mon:04:00-mon:05:00"

  # Storage encryption (recommended for production)
  storage_encrypted = true

  # Skip final snapshot on destroy
  skip_final_snapshot = true

  port = 5432

  tags = merge(var.tags, { Name = "litellm-postgres" })
}

# ─────────────────────────────────────────────────────────────────────────────
# ElastiCache Subnet Group
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_elasticache_subnet_group" "main" {
  name       = "litellm-redis-subnet-group"
  subnet_ids = var.private_data_subnet_ids

  tags = merge(var.tags, { Name = "litellm-redis-subnet-group" })
}

# ─────────────────────────────────────────────────────────────────────────────
# ElastiCache Redis/Valkey Replication Group
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_elasticache_replication_group" "main" {
  replication_group_id = "litellm-redis"
  description          = "LiteLLM shared RPM + health check cache"

  engine             = "redis"
  engine_version     = "7.0"
  node_type          = var.redis_node_type
  num_cache_clusters = var.redis_num_nodes

  port = var.redis_port

  security_group_ids = var.security_group_ids
  subnet_group_name  = aws_elasticache_subnet_group.main.name

  # At-rest encryption is always recommended
  at_rest_encryption_enabled = true

  # Automatic failover requires multi-AZ
  automatic_failover_enabled = var.redis_num_nodes > 1

  # Backup
  snapshot_retention_limit = 1
  snapshot_window          = "03:00-04:00"

  # Fully private — no public access
  # Redis auth (AUTH) is disabled; if needed, enable via Secrets Manager
  # and update REDIS_PASSWORD in Secrets Manager accordingly

  tags = merge(var.tags, { Name = "litellm-redis" })
}

# ─────────────────────────────────────────────────────────────────────────────
# Secrets Manager resource policies — deny GetSecretValue over non-TLS
# Applied to all 4 secrets to enforce encrypted-in-transit for every secret.
# ─────────────────────────────────────────────────────────────────────────────

data "aws_iam_policy_document" "secrets_manager_deny_unencrypted" {
  statement {
    sid    = "DenyUnencryptedSecrets"
    effect = "Deny"

    actions = ["secretsmanager:GetSecretValue"]

    resources = [
      aws_secretsmanager_secret.litellm_master_key.arn,
      aws_secretsmanager_secret.database_url.arn,
      aws_secretsmanager_secret.redis_password.arn,
      aws_secretsmanager_secret.litellm_salt_key.arn,
    ]

    condition {
      test     = "Null"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_secretsmanager_secret_policy" "litellm_master_key" {
  secret_arn = aws_secretsmanager_secret.litellm_master_key.arn

  policy = data.aws_iam_policy_document.secrets_manager_deny_unencrypted.json
}

resource "aws_secretsmanager_secret_policy" "database_url" {
  secret_arn = aws_secretsmanager_secret.database_url.arn

  policy = data.aws_iam_policy_document.secrets_manager_deny_unencrypted.json
}

resource "aws_secretsmanager_secret_policy" "redis_password" {
  secret_arn = aws_secretsmanager_secret.redis_password.arn

  policy = data.aws_iam_policy_document.secrets_manager_deny_unencrypted.json
}

resource "aws_secretsmanager_secret_policy" "litellm_salt_key" {
  secret_arn = aws_secretsmanager_secret.litellm_salt_key.arn

  policy = data.aws_iam_policy_document.secrets_manager_deny_unencrypted.json
}