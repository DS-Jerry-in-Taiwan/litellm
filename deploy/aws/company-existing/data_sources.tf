# =============================================================================
# Existing AWS Resource Data Sources — Read-only
# =============================================================================
# Phase 0 — Scaffold. These data sources read company existing resources.
# Terraform will NOT manage, modify, or destroy these resources.
# =============================================================================

# ─────────────────────────────────────────────────────────────────────────────
# Existing VPC
# ─────────────────────────────────────────────────────────────────────────────

data "aws_vpc" "existing" {
  id = var.existing_vpc_id
}

# ─────────────────────────────────────────────────────────────────────────────
# Existing Subnets (data only, no management)
# ─────────────────────────────────────────────────────────────────────────────

data "aws_subnet" "private_app" {
  for_each = toset(var.existing_private_app_subnet_ids)
  id       = each.key
}

data "aws_subnet" "private_data" {
  for_each = toset(var.existing_private_data_subnet_ids)
  id       = each.key
}

# ─────────────────────────────────────────────────────────────────────────────
# Existing Aurora Cluster
# ─────────────────────────────────────────────────────────────────────────────

data "aws_rds_cluster" "existing" {
  cluster_identifier = var.existing_aurora_cluster_identifier
}

# ─────────────────────────────────────────────────────────────────────────────
# Existing Security Groups (optional — only if IDs are provided)
# ─────────────────────────────────────────────────────────────────────────────

data "aws_security_group" "ecs" {
  count = var.existing_ecs_security_group_id != "" ? 1 : 0
  id    = var.existing_ecs_security_group_id
}

data "aws_security_group" "data" {
  count = var.existing_data_security_group_id != "" ? 1 : 0
  id    = var.existing_data_security_group_id
}
