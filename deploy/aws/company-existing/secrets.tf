# =============================================================================
# Secrets Manager — Phase 1: P0 Safety Baseline
# =============================================================================
# Stores LiteLLM sensitive configuration in AWS Secrets Manager.
# Terraform only manages the secret resources (ARN/id); secret values are
# set by the customer outside of Terraform (e.g., via AWS Console or CLI).
# Secrets are referenced by ECS task definition via `valueFrom`.
#
# References:
#   - litellm_master_key   : var.litellm_master_key  (input, sensitive)
#   - litellm_salt_key     : var.litellm_salt_key    (input, sensitive)
#   - litellm_database_url : constructed from data.aws_rds_cluster.existing.endpoint
# =============================================================================

resource "aws_secretsmanager_secret" "litellm_master_key" {
  name        = "${local.name_prefix}-master-key"
  description = "LiteLLM master key used for API authentication"
  tags        = local.common_tags

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_secretsmanager_secret" "litellm_database_url" {
  name        = "${local.name_prefix}-database-url"
  description = "PostgreSQL connection string for LiteLLM. Endpoint sourced from existing Aurora cluster '${data.aws_rds_cluster.existing.cluster_identifier}'."
  tags        = local.common_tags

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_secretsmanager_secret" "litellm_salt_key" {
  name        = "${local.name_prefix}-salt-key"
  description = "LiteLLM salt key used for request signing/encryption"
  tags        = local.common_tags

  lifecycle {
    prevent_destroy = true
  }
}
