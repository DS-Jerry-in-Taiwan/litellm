# ─────────────────────────────────────────────────────────────────────────────
# ECS Cluster — Fargate
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_ecs_cluster" "main" {
  name = local.name_prefix
  tags = local.common_tags
}

# ─────────────────────────────────────────────────────────────────────────────
# ECS Task Definition
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_ecs_task_definition" "litellm" {
  family                   = local.name_prefix
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.ecs_task_cpu
  memory                   = var.ecs_task_memory
  execution_role_arn       = aws_iam_role.ecs_execution.arn
  task_role_arn            = aws_iam_role.ecs_task.arn

  container_definitions = jsonencode([
    {
      name  = "litellm"
      image = local.ecr_image

      portMappings = [
        {
          containerPort = var.container_port
          protocol      = "tcp"
        }
      ]

      environment = [
        {
          name  = "S3_CONFIG_URL"
          value = "s3://${aws_s3_bucket.config.id}/config.yaml"
        },
        {
          name  = "STORE_MODEL_IN_DB"
          value = var.store_model_in_db
        },
        {
          name  = "UI_USERNAME"
          value = var.ui_username
        },
        {
          name  = "UI_PASSWORD"
          value = var.ui_password
        },
        {
          name  = "REDIS_HOST"
          value = local.redis_host
        },
        {
          name  = "REDIS_PORT"
          value = tostring(var.redis_port)
        },
        {
          name  = "REDIS_PASSWORD"
          value = ""
        }
      ]

      secrets = concat(
        [
          {
            name      = "LITELLM_MASTER_KEY"
            valueFrom = aws_secretsmanager_secret.litellm_master_key.arn
          },
          {
            name      = "LITELLM_SALT_KEY"
            valueFrom = aws_secretsmanager_secret.litellm_salt_key.arn
          },
        ],
        local.deploy.db_secret ? [
          {
            name      = "DATABASE_URL"
            valueFrom = aws_secretsmanager_secret.litellm_database_url[0].arn
          }
        ] : []
      )

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.ecs.name
          "awslogs-region"        = var.region
          "awslogs-stream-prefix" = "ecs"
        }
      }

      healthCheck = {
        command     = ["CMD-SHELL", "curl -f http://localhost:${var.container_port}/health/liveliness || exit 1"]
        interval    = 30
        timeout     = 5
        retries     = 3
        startPeriod = 60
      }
    }
  ])

  tags = local.common_tags
}

# ─────────────────────────────────────────────────────────────────────────────
# Config Redeploy Trigger
# ─────────────────────────────────────────────────────────────────────────────
# When the S3 config object's etag changes (i.e., a new config.yaml is
# uploaded), this terraform_data resource's output changes, which triggers
# the ECS service to force a new deployment.
# ─────────────────────────────────────────────────────────────────────────────

resource "terraform_data" "force_deploy" {
  input = var.proxy_config_source != "" ? aws_s3_object.config.etag : ""
}

# ─────────────────────────────────────────────────────────────────────────────
# ECS Service
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_ecs_service" "litellm" {
  name            = local.name_prefix
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.litellm.arn
  desired_count   = var.ecs_desired_count
  launch_type     = "FARGATE"

  # Force new deployment when S3 config etag changes
  force_new_deployment = var.proxy_config_source != "" ? true : null

  deployment_circuit_breaker {
    enable   = var.ecs_deployment_circuit_breaker_enable
    rollback = var.ecs_deployment_circuit_breaker_rollback
  }

  network_configuration {
    subnets          = var.existing_private_app_subnet_ids
    security_groups  = var.existing_ecs_security_group_id != "" ? [var.existing_ecs_security_group_id] : [aws_security_group.ecs[0].id]
    assign_public_ip = var.assign_public_ip
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.litellm.arn
    container_name   = "litellm"
    container_port   = var.container_port
  }

  depends_on = [aws_lb_listener.http]

  tags = local.common_tags
}
