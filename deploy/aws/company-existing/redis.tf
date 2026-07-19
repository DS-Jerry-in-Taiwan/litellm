# =============================================================================
# Redis / ElastiCache — Phase 3: Data/Cache Layer
# =============================================================================
# Creates ElastiCache Redis for LiteLLM shared cache / RPM-TPM counters.
# Supports dual-mode: managed Redis or external existing Redis host.
#
# B1 Expert-review guard: local.redis_security_group_id MUST use nested
#   `var.create_redis ? aws_security_group.redis[0].id : ""` guard.
#   Using a flat `existing_data_security_group_id != "" ? ... : aws_security_group.redis[0].id`
#   would cause an index error when both create_redis=false and
#   existing_data_security_group_id="" (the default).
#
# Redis AUTH is intentionally disabled (redis_auth_enabled=false) to avoid
# storing auth tokens in Terraform state. A future Secrets Manager AUTH phase
# will add proper secret injection.
# =============================================================================

locals {
  # Whether any Redis mode is active (managed or external)
  redis_enabled = var.create_redis || var.redis_host != ""

  # Redis host: managed endpoint or external host
  redis_host = var.create_redis ? aws_elasticache_replication_group.redis[0].primary_endpoint_address : var.redis_host

  # B1 guard: only reference aws_security_group.redis[0] when it exists
  redis_security_group_id = (
    var.existing_data_security_group_id != "" ? var.existing_data_security_group_id : (
      var.create_redis ? aws_security_group.redis[0].id : ""
    )
  )
}

# ─────────────────────────────────────────────────────────────────────────────
# Redis Security Group — only created when Redis is managed AND no existing SG
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_security_group" "redis" {
  count       = var.create_redis && var.existing_data_security_group_id == "" ? 1 : 0
  name        = "${local.name_prefix}-redis"
  description = "Security group for LiteLLM Redis"
  vpc_id      = var.existing_vpc_id
  tags        = local.common_tags
}

# Allow ECS to connect to Redis on redis_port
resource "aws_vpc_security_group_ingress_rule" "redis_from_ecs" {
  count = var.create_redis && var.existing_data_security_group_id == "" ? 1 : 0

  security_group_id = aws_security_group.redis[0].id
  from_port         = var.redis_port
  to_port           = var.redis_port
  ip_protocol       = "tcp"
  description       = "Allow ECS to connect to Redis"

  # Use existing ECS SG if provided, otherwise reference the Terraform-managed ECS SG
  referenced_security_group_id = var.existing_ecs_security_group_id != "" ? var.existing_ecs_security_group_id : aws_security_group.ecs[0].id
}

# ─────────────────────────────────────────────────────────────────────────────
# Redis Subnet Group
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_elasticache_subnet_group" "redis" {
  count      = var.create_redis ? 1 : 0
  name       = "${local.name_prefix}-redis-subnet-group"
  subnet_ids = var.existing_private_data_subnet_ids
  tags       = local.common_tags
}

# ─────────────────────────────────────────────────────────────────────────────
# Redis Replication Group
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_elasticache_replication_group" "redis" {
  count                = var.create_redis ? 1 : 0
  replication_group_id = "${local.name_prefix}-redis"
  description          = "LiteLLM shared cache and rate-limit counters"

  engine             = "redis"
  engine_version     = "7.0"
  node_type          = var.redis_node_type
  num_cache_clusters = var.redis_num_cache_clusters
  port               = var.redis_port
  subnet_group_name  = aws_elasticache_subnet_group.redis[0].name
  security_group_ids = [local.redis_security_group_id]

  at_rest_encryption_enabled = true
  automatic_failover_enabled = var.redis_num_cache_clusters > 1
  snapshot_retention_limit   = 1
  snapshot_window            = "03:00-04:00"

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-redis" })
}
