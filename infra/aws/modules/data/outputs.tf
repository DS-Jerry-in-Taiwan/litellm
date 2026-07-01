# =============================================================================
# Data Module Outputs
# =============================================================================

# ── Secrets Manager ARNs ──────────────────────────────────────────────────────

output "litellm_master_key_arn" {
  description = "ARN of the LITELLM_MASTER_KEY Secrets Manager secret."
  value       = aws_secretsmanager_secret.litellm_master_key.arn
}

output "database_url_arn" {
  description = "ARN of the DATABASE_URL Secrets Manager secret."
  value       = aws_secretsmanager_secret.database_url.arn
}

output "redis_password_arn" {
  description = "ARN of the REDIS_PASSWORD Secrets Manager secret."
  value       = aws_secretsmanager_secret.redis_password.arn
}

output "litellm_salt_key_arn" {
  description = "ARN of the LITELLM_SALT_KEY Secrets Manager secret."
  value       = aws_secretsmanager_secret.litellm_salt_key.arn
}

output "openai_api_key_arn" {
  description = <<-EOT
    ARN of the OPENAI_API_KEY SSM parameter.
    Empty string when create_ssm_parameter_openai_key = false.
    If empty, the SSM parameter must be created manually before ECS deployment:
      aws ssm put-parameter --name "litellm/openai-api-key" \
        --value "sk-real-key" --type SecureString --overwrite
  EOT
  value       = var.create_ssm_parameter_openai_key ? aws_ssm_parameter.openai_api_key[0].arn : ""
}

# ── CloudWatch ────────────────────────────────────────────────────────────────

output "cloudwatch_log_group_name" {
  description = "CloudWatch log group name for ECS container logs."
  value       = aws_cloudwatch_log_group.ecs.name
}

output "cloudwatch_log_group_arn" {
  description = "ARN of the CloudWatch log group."
  value       = aws_cloudwatch_log_group.ecs.arn
}

# ── RDS ───────────────────────────────────────────────────────────────────────

output "rds_endpoint" {
  description = "RDS PostgreSQL endpoint (use DATABASE_URL from Secrets Manager in app)."
  value       = aws_db_instance.main.endpoint
}

output "rds_arn" {
  description = "ARN of the RDS instance."
  value       = aws_db_instance.main.arn
}

output "rds_port" {
  description = "RDS PostgreSQL port."
  value       = aws_db_instance.main.port
}

# ── ElastiCache ───────────────────────────────────────────────────────────────

output "redis_endpoint" {
  description = "ElastiCache Redis/Valkey primary endpoint (use as REDIS_HOST in ECS env)."
  value       = aws_elasticache_replication_group.main.primary_endpoint_address
}

output "redis_arn" {
  description = "ARN of the ElastiCache replication group."
  value       = aws_elasticache_replication_group.main.arn
}

output "redis_port" {
  description = "ElastiCache Redis/Valkey port."
  value       = aws_elasticache_replication_group.main.port
}