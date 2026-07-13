# =============================================================================
# ECR Module Outputs
# =============================================================================

output "repository_url" {
  description = "URL of the ECR repository. Use for docker tag/push."
  value       = aws_ecr_repository.litellm.repository_url
}

output "repository_name" {
  description = "Name of the ECR repository."
  value       = aws_ecr_repository.litellm.name
}

output "repository_arn" {
  description = "ARN of the ECR repository."
  value       = aws_ecr_repository.litellm.arn
}