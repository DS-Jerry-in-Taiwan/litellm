# =============================================================================
# Migration Task — One-time DB migration for LiteLLM
# =============================================================================
# This task definition is for ECS RunTask API (not a Service).
# Execute with:
#   aws ecs run-task --cluster litellm --task-definition litellm-migration
# =============================================================================

resource "aws_ecs_task_definition" "migration" {
  family                   = "${local.name_prefix}-migration"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.ecs_task_cpu
  memory                   = var.ecs_task_memory
  execution_role_arn       = aws_iam_role.ecs_execution.arn
  task_role_arn            = aws_iam_role.ecs_task.arn

  container_definitions = jsonencode([
    {
      name  = "litellm-migration"
      image = "${var.ecr_repository_arn}:${var.image_tag}"

      environment = [
        {
          name  = "LITELLM_MODE"
          value = "migrate"
        },
        {
          name  = "S3_CONFIG_URL"
          value = "s3://${aws_s3_bucket.config.id}/config.yaml"
        }
      ]

      secrets = [
        {
          name      = "LITELLM_MASTER_KEY"
          valueFrom = aws_secretsmanager_secret.litellm_master_key.arn
        },
        {
          name      = "DATABASE_URL"
          valueFrom = aws_secretsmanager_secret.litellm_database_url.arn
        },
        {
          name      = "LITELLM_SALT_KEY"
          valueFrom = aws_secretsmanager_secret.litellm_salt_key.arn
        }
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.ecs.name
          "awslogs-region"        = var.region
          "awslogs-stream-prefix" = "migration"
        }
      }
    }
  ])

  tags = local.common_tags
}
