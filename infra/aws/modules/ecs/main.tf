# =============================================================================
# ECS Module — Cluster, Task Definition, Service, ALB, IAM
# =============================================================================

# ─────────────────────────────────────────────────────────────────────────────
# IAM — ECS Execution Role (pulls image, writes logs)
# ─────────────────────────────────────────────────────────────────────────────

data "aws_iam_policy_document" "ecs_execution_assume_role" {
  statement {
    sid     = "ECSTaskExecutionAssumeRole"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ecs_execution" {
  name               = "litellm-ecs-execution-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_execution_assume_role.json

  tags = merge(var.tags, { Name = "litellm-ecs-execution-role" })
}

resource "aws_iam_role_policy" "ecs_execution" {
  name = "litellm-ecs-execution-policy"
  role = aws_iam_role.ecs_execution.id

  # SSM parameter read is conditionally included only when openai_api_key_arn is non-empty.
  # When create_ssm_parameter_openai_key=false, the SSM parameter does not exist and
  # IAM must not reference a non-existent ARN.
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      [
        {
          Sid    = "ECRPull"
          Effect = "Allow"
          Action = [
            "ecr:GetAuthorizationToken",
            "ecr:BatchCheckLayerAvailability",
            "ecr:GetDownloadUrlForLayer",
            "ecr:BatchGetImage",
          ]
          Resource = "*"
        },
        {
          Sid    = "CloudWatchLogs"
          Effect = "Allow"
          Action = [
            "logs:CreateLogStream",
            "logs:PutLogEvents",
          ]
          Resource = "${var.cloudwatch_log_group_arn}:*"
        },
        {
          Sid    = "SecretsManagerRead"
          Effect = "Allow"
          Action = [
            "secretsmanager:GetSecretValue",
          ]
          Resource = [
            var.litellm_master_key_arn,
            var.database_url_arn,
            var.redis_password_arn,
            var.litellm_salt_key_arn,
          ]
        },
      ],
      (
        var.openai_api_key_arn != ""
        ? [{
          Sid      = "SSMParameterRead"
          Effect   = "Allow"
          Action   = ["ssm:GetParameters"]
          Resource = [var.openai_api_key_arn]
        }]
        : []
      )
    )
  })
}

# ─────────────────────────────────────────────────────────────────────────────
# IAM — ECS Task Role (app runtime — makes provider API calls)
# ─────────────────────────────────────────────────────────────────────────────

data "aws_iam_policy_document" "ecs_task_assume_role" {
  statement {
    sid     = "ECSTaskAssumeRole"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ecs_task" {
  name               = "litellm-ecs-task-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_task_assume_role.json

  tags = merge(var.tags, { Name = "litellm-ecs-task-role" })
}

resource "aws_iam_role_policy" "ecs_task" {
  name = "litellm-ecs-task-policy"
  role = aws_iam_role.ecs_task.id

  # Allow outbound HTTPS for provider API calls
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "CloudWatchLogs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents",
        ]
        Resource = "*"
      },
    ]
  })
}

# ─────────────────────────────────────────────────────────────────────────────
# ECS Cluster
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_ecs_cluster" "main" {
  name = var.ecs_cluster_name

  setting {
    name  = "containerInsights"
    value = "enabled"
  }

  tags = merge(var.tags, { Name = "litellm-ecs-cluster" })
}

# ─────────────────────────────────────────────────────────────────────────────
# ECS Task Definition
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_ecs_task_definition" "litellm" {
  family                   = "litellm"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = var.ecs_task_cpu
  memory                   = var.ecs_task_memory
  execution_role_arn       = aws_iam_role.ecs_execution.arn
  task_role_arn            = aws_iam_role.ecs_task.arn

  container_definitions = jsonencode([
    {
      name      = "litellm"
      image     = "${var.ecr_repository_url}:${var.image_tag}"
      essential = true

      portMappings = [
        {
          containerPort = var.container_port
          protocol      = "tcp"
        }
      ]

      environment = [
        {
          name  = "REDIS_HOST"
          value = var.redis_host
        },
        {
          name  = "REDIS_PORT"
          value = tostring(var.redis_port)
        },
        {
          name  = "STORE_MODEL_IN_DB"
          value = "True"
        },
      ]

      # Secrets list — OPENAI_API_KEY is conditionally included only when
      # openai_api_key_arn is non-empty. This prevents the ECS task definition
      # from referencing an empty SSM parameter ARN when create_ssm_parameter_openai_key=false.
      secrets = concat(
        [
          {
            name      = "DATABASE_URL"
            valueFrom = var.database_url_arn
          },
          {
            name      = "LITELLM_MASTER_KEY"
            valueFrom = var.litellm_master_key_arn
          },
          {
            name      = "LITELLM_SALT_KEY"
            valueFrom = var.litellm_salt_key_arn
          },
          {
            name      = "REDIS_PASSWORD"
            valueFrom = var.redis_password_arn
          },
        ],
        (
          var.openai_api_key_arn != ""
          ? [{ name = "OPENAI_API_KEY", valueFrom = var.openai_api_key_arn }]
          : []
        )
      )

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = var.cloudwatch_log_group_name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "ecs"
        }
      }

      healthCheck = {
        command     = ["CMD-SHELL", "python3 -c \"import urllib.request, sys; sys.exit(0) if urllib.request.urlopen('http://localhost:4000/health/liveliness').status == 200 else sys.exit(1)\""]
        interval    = 30
        timeout     = 10
        retries     = 3
        startPeriod = 60
      }
    }
  ])

  tags = merge(var.tags, { Name = "litellm-task-def" })
}

# ─────────────────────────────────────────────────────────────────────────────
# ALB — Application Load Balancer
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_lb" "main" {
  name               = var.alb_name
  internal           = false
  load_balancer_type = "application"

  subnets = var.public_subnet_ids

  security_groups = [var.alb_security_group_id]

  enable_deletion_protection = false # Set to true for production

  tags = merge(var.tags, { Name = "litellm-alb" })
}

# ─────────────────────────────────────────────────────────────────────────────
# ALB Target Group
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_lb_target_group" "litellm" {
  name     = "${var.alb_name}-tg"
  port     = var.container_port
  protocol = "HTTP"
  vpc_id   = var.vpc_id

  deregistration_delay = 30
  target_type          = "ip"

  health_check {
    enabled             = true
    path                = var.alb_health_check_path
    port                = "traffic-port"
    protocol            = "HTTP"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = 10
    interval            = 30
    matcher             = var.alb_health_check_matcher
  }

  tags = merge(var.tags, { Name = "litellm-alb-tg" })
}

# ─────────────────────────────────────────────────────────────────────────────
# ALB HTTP Listener (port 80)
# Behavior depends on whether an ACM certificate is configured:
#   - With ACM cert (prd-like): redirect all HTTP → HTTPS (301)
#   - Without ACM cert (dev/staging): forward HTTP directly to ECS (plaintext)
# ECS tasks receive decrypted traffic on port 4000 either way (ALB terminates TLS).
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = "80"
  protocol          = "HTTP"

  # When acm_certificate_arn is set: redirect HTTP → HTTPS
  # When empty (dev only): forward to ECS target group (plaintext)
  # Uses dynamic blocks because default_action must be a block, not a computed argument.
  dynamic "default_action" {
    for_each = var.acm_certificate_arn != "" ? [1] : []
    content {
      type = "redirect"
      redirect {
        port        = "443"
        protocol    = "HTTPS"
        status_code = "HTTP_301"
      }
    }
  }

  dynamic "default_action" {
    for_each = var.acm_certificate_arn == "" ? [1] : []
    content {
      type             = "forward"
      target_group_arn = aws_lb_target_group.litellm.arn
    }
  }

  tags = merge(var.tags, { Name = "litellm-alb-http-listener" })
}

# ─────────────────────────────────────────────────────────────────────────────
# ALB HTTPS Listener (conditional — requires ACM certificate ARN)
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_lb_listener" "https" {
  count = var.acm_certificate_arn != "" ? 1 : 0

  load_balancer_arn = aws_lb.main.arn
  port              = "443"
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = var.acm_certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.litellm.arn
  }

  tags = merge(var.tags, { Name = "litellm-alb-https-listener" })
}

# ─────────────────────────────────────────────────────────────────────────────
# ECS Service
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_ecs_service" "main" {
  name            = "${var.ecs_cluster_name}-service"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.litellm.arn
  desired_count   = var.ecs_desired_count
  launch_type     = "FARGATE"

  # Enable rolling deployment
  deployment_controller {
    type = "ECS"
  }

  deployment_maximum_percent         = 200
  deployment_minimum_healthy_percent = 100

  # Wait for ALB target group to be registered
  load_balancer {
    target_group_arn = aws_lb_target_group.litellm.arn
    container_name   = "litellm"
    container_port   = var.container_port
  }

  network_configuration {
    subnets          = var.private_app_subnet_ids
    security_groups  = [var.ecs_security_group_id]
    assign_public_ip = false
  }

  # Prevent Terraform from reverting health check modifications
  # (ECS will fail tasks that don't pass the health check)
  health_check_grace_period_seconds = 60

  tags = merge(var.tags, { Name = "litellm-ecs-service" })

  depends_on = [
    aws_lb_listener.http,
    aws_lb.main,
  ]
}

# ─────────────────────────────────────────────────────────────────────────────
# ECS Autoscaling
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_appautoscaling_target" "ecs" {
  max_capacity       = var.ecs_max_capacity
  min_capacity       = var.ecs_min_capacity
  resource_id        = "service/${aws_ecs_cluster.main.name}/${aws_ecs_service.main.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"
}

resource "aws_appautoscaling_policy" "cpu" {
  name               = "litellm-cpu-autoscaling"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.ecs.resource_id
  scalable_dimension = aws_appautoscaling_target.ecs.scalable_dimension
  service_namespace  = aws_appautoscaling_target.ecs.service_namespace

  target_tracking_scaling_policy_configuration {
    target_value       = 70
    scale_in_cooldown  = 60
    scale_out_cooldown = 60

    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
  }
}

resource "aws_appautoscaling_policy" "memory" {
  name               = "litellm-memory-autoscaling"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.ecs.resource_id
  scalable_dimension = aws_appautoscaling_target.ecs.scalable_dimension
  service_namespace  = aws_appautoscaling_target.ecs.service_namespace

  target_tracking_scaling_policy_configuration {
    target_value       = 80
    scale_in_cooldown  = 60
    scale_out_cooldown = 60

    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageMemoryUtilization"
    }
  }
}