# ─────────────────────────────────────────────────────────────────────────────
# Security Groups for ALB and ECS Tasks
# ─────────────────────────────────────────────────────────────────────────────
# ALB SG: Allow inbound HTTP traffic from VPC CIDR (internal ALB)
# ECS Tasks SG: Allow inbound from ALB SG on port 4000
# ─────────────────────────────────────────────────────────────────────────────

# If existing ECS SG is provided, skip creating a new one
resource "aws_security_group" "ecs" {
  count       = var.existing_ecs_security_group_id != "" ? 0 : 1
  name        = "${local.name_prefix}-ecs-tasks"
  description = "Security group for LiteLLM ECS tasks"
  vpc_id      = var.existing_vpc_id
  tags        = local.common_tags
}

resource "aws_vpc_security_group_ingress_rule" "ecs_from_alb" {
  count = var.existing_ecs_security_group_id != "" ? 0 : 1

  security_group_id = aws_security_group.ecs[0].id

  description = "Allow ALB traffic to ECS on container port"
  from_port   = var.container_port
  to_port     = var.container_port
  ip_protocol = "tcp"

  referenced_security_group_id = aws_security_group.alb.id
}

resource "aws_security_group" "alb" {
  name        = "${local.name_prefix}-alb"
  description = "Security group for LiteLLM ALB"
  vpc_id      = var.existing_vpc_id
  tags        = local.common_tags
}

resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  security_group_id = aws_security_group.alb.id

  description = "Allow HTTP from VPC"
  from_port   = 80
  to_port     = 80
  ip_protocol = "tcp"
  cidr_ipv4   = data.aws_vpc.existing.cidr_block
}

resource "aws_vpc_security_group_egress_rule" "alb_to_ecs" {
  security_group_id = aws_security_group.alb.id

  description = "Allow ALB to forward to ECS tasks"
  from_port   = var.container_port
  to_port     = var.container_port
  ip_protocol = "tcp"

  referenced_security_group_id = aws_security_group.ecs[0].id
}

resource "aws_vpc_security_group_egress_rule" "ecs_to_data" {
  count = var.existing_ecs_security_group_id != "" ? 0 : 1

  security_group_id = aws_security_group.ecs[0].id

  description = "Allow ECS outbound to data layer"
  ip_protocol = "-1"
  cidr_ipv4   = "0.0.0.0/0"
}
