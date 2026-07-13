# =============================================================================
# ECS Module Outputs
# =============================================================================

output "ecs_cluster_name" {
  description = "Name of the ECS cluster."
  value       = aws_ecs_cluster.main.name
}

output "ecs_cluster_arn" {
  description = "ARN of the ECS cluster."
  value       = aws_ecs_cluster.main.arn
}

output "ecs_service_name" {
  description = "Name of the ECS service."
  value       = aws_ecs_service.main.name
}

output "ecs_service_arn" {
  description = "ARN of the ECS service."
  value       = aws_ecs_service.main.id
}

output "ecs_task_definition_family" {
  description = "Family of the ECS task definition."
  value       = aws_ecs_task_definition.litellm.family
}

output "ecs_execution_role_arn" {
  description = "ARN of the ECS execution role."
  value       = aws_iam_role.ecs_execution.arn
}

output "ecs_task_role_arn" {
  description = "ARN of the ECS task role."
  value       = aws_iam_role.ecs_task.arn
}

# ── ALB ───────────────────────────────────────────────────────────────────────

output "alb_dns_name" {
  description = <<-EOT
    DNS name of the Application Load Balancer.
    Use as LITELLM_BASE_URL in smoke tests after deployment:
      export LITELLM_BASE_URL="http://<alb_dns_name>"
    For HTTPS in production, use the ACM certificate-bound DNS name.
  EOT
  value       = aws_lb.main.dns_name
}

output "alb_zone_id" {
  description = "Zone ID of the ALB (for Route53 alias records)."
  value       = aws_lb.main.zone_id
}

output "alb_arn" {
  description = "ARN of the Application Load Balancer."
  value       = aws_lb.main.arn
}

output "alb_http_listener_arn" {
  description = "ARN of the ALB HTTP listener (port 80)."
  value       = aws_lb_listener.http.arn
}

output "alb_https_listener_arn" {
  description = "ARN of the ALB HTTPS listener (port 443). Empty string if ACM cert not configured."
  value       = length(aws_lb_listener.https) > 0 ? aws_lb_listener.https[0].arn : ""
}

output "alb_security_group_id" {
  description = "Security group ID of the ALB."
  value       = var.alb_security_group_id
}

output "ecs_security_group_id" {
  description = "Security group ID of the ECS tasks."
  value       = var.ecs_security_group_id
}