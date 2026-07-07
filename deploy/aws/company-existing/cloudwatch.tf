# =============================================================================
# CloudWatch Log Group — Phase 1: P0 Safety Baseline
# =============================================================================
# ECS container logs are written here via the ECS execution role.
# Retention of 30 days balances observability with storage cost.
#
# References:
#   - Consumed by aws_iam_role.ecs_execution (cloudwatch.tf reference)
#   - Consumed by aws_iam_role.ecs_task     (cloudwatch.tf reference)
# =============================================================================

resource "aws_cloudwatch_log_group" "ecs" {
  name              = "/ecs/${local.name_prefix}"
  retention_in_days = 30
  tags              = local.common_tags

  lifecycle {
    prevent_destroy = true
  }
}
