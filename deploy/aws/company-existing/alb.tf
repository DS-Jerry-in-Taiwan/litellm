# ─────────────────────────────────────────────────────────────────────────────
# Application Load Balancer — Internal
# ─────────────────────────────────────────────────────────────────────────────
# Internal ALB in private app subnets. HTTPS will be added in Phase 5.
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_lb" "main" {
  name               = var.alb_name
  internal           = true
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = var.existing_private_app_subnet_ids
  tags               = local.common_tags
}

# ─────────────────────────────────────────────────────────────────────────────
# Target Group
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_lb_target_group" "litellm" {
  name        = local.name_prefix
  port        = var.container_port
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = var.existing_vpc_id

  health_check {
    enabled             = true
    path                = var.alb_health_check_path
    port                = "traffic-port"
    protocol            = "HTTP"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = 5
    interval            = 30
    matcher             = var.alb_health_check_matcher
  }

  tags = local.common_tags
}

# ─────────────────────────────────────────────────────────────────────────────
# Listener — HTTP (port 80)
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.litellm.arn
  }
}
