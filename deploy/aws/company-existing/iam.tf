# =============================================================================
# IAM Roles — Phase 1: P0 Safety Baseline
# =============================================================================
# Two distinct IAM roles for ECS:
#   1. ECS Execution Role — attached to the task infrastructure (pull image,
#      fetch secrets, write logs). Assumed by the ECS agent (ecs-tasks.amazonaws.com).
#   2. ECS Task Role — the runtime identity of the container itself. Assumed
#      by the container process inside the task.
#
# Design principles:
#   - Least privilege: permissions are scoped to specific resource ARNs.
#   - ECR GetAuthorizationToken uses Resource="*" per AWS API requirement.
#   - No wildcard in SecretsManager or CloudWatch permissions.
# =============================================================================

# ─────────────────────────────────────────────────────────────────────────────
# ECS Execution Role
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_iam_role" "ecs_execution" {
  name = "${local.name_prefix}-ecs-execution"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ECSTaskExecutionAssume"
        Effect = "Allow"
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = local.common_tags

  lifecycle {
    create_before_destroy = true
    prevent_destroy       = true
  }
}

resource "aws_iam_role_policy" "ecs_execution" {
  name = "${local.name_prefix}-ecs-execution"
  role = aws_iam_role.ecs_execution.id

  # Terraform intentionally omits lifecycle.prevent_destroy here so that
  # destroy-and-recreate is possible when the role must be replaced.
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # ECR: GetAuthorizationToken is org-level — Resource must be "*"
        # https://docs.aws.amazon.com/AmazonECR/latest/userguide/security-iam.html
        Sid    = "ECRAuthorizationToken"
        Effect = "Allow"
        Action = [
          "ecr:GetAuthorizationToken"
        ]
        Resource = "*"
      },
      {
        # ECR: Pull image from the LiteLLM repository
        # Scoped to the specific ECR repository ARN provided via var.ecr_repository_arn.
        Sid    = "ECRPullLiteLLM"
        Effect = "Allow"
        Action = [
          "ecr:BatchGetImage",
          "ecr:GetDownloadUrlForLayer"
        ]
        Resource = var.ecr_repository_arn
      },
      {
        # CloudWatch Logs: Write container logs
        # Restricted to the specific log group created in cloudwatch.tf.
        Sid    = "CloudWatchLogs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "${aws_cloudwatch_log_group.ecs.arn}:*"
      },
      {
        # SecretsManager: Fetch LiteLLM secrets at container start
        # Scoped to the 3 secrets created in secrets.tf — no other secrets.
        Sid    = "SecretsManagerLitellm"
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue"
        ]
        Resource = [
          aws_secretsmanager_secret.litellm_master_key.arn,
          aws_secretsmanager_secret.litellm_database_url.arn,
          aws_secretsmanager_secret.litellm_salt_key.arn,
        ]
      }
    ]
  })
}

# ─────────────────────────────────────────────────────────────────────────────
# ECS Task Role — skeleton for Phase 1
# ─────────────────────────────────────────────────────────────────────────────
# Phase 1: Container runtime has no AWS API calls beyond CloudWatch logs.
# This role is assumed by the container process (not the ECS agent).
# Additional permissions (S3, etc.) will be added in Phase 3+.

resource "aws_iam_role" "ecs_task" {
  name = "${local.name_prefix}-ecs-task"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ECSTaskAssume"
        Effect = "Allow"
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = local.common_tags

  lifecycle {
    create_before_destroy = true
    prevent_destroy       = true
  }
}

resource "aws_iam_role_policy" "ecs_task" {
  name = "${local.name_prefix}-ecs-task"
  role = aws_iam_role.ecs_task.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # CloudWatch Logs: Container app logs (not the ECS agent/infra logs)
        Sid    = "CloudWatchLogsTask"
        Effect = "Allow"
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "${aws_cloudwatch_log_group.ecs.arn}:*"
      },
      {
        # S3: Read LiteLLM proxy config from the config bucket
        Sid    = "S3ReadConfig"
        Effect = "Allow"
        Action = [
          "s3:GetObject"
        ]
        Resource = "${aws_s3_bucket.config.arn}/*"
      }
    ]
  })
}
