# =============================================================================
# Production Variables
# =============================================================================

variable "region" {
  description = "AWS region to deploy into (e.g. us-east-1)"
  type        = string
}

variable "azs" {
  description = "List of availability zones for the VPC (minimum 2)"
  type        = list(string)
}

variable "tenant" {
  description = "Tenant identifier (e.g. company name)"
  type        = string
}

variable "env" {
  description = "Environment name (e.g. production, staging)"
  type        = string
}

variable "litellm_master_key" {
  description = "LiteLLM master key (stored in AWS Secrets Manager)"
  type        = string
  sensitive   = true
}

variable "allow_plaintext_alb" {
  description = "Allow HTTP-only ALB (set true for dev/trial, false for production with ACM)"
  type        = bool
  default     = false
}

variable "skip_final_snapshot" {
  description = "Skip final snapshot on RDS destroy (true for test, false for production)"
  type        = bool
  default     = false
}

variable "s3_force_destroy" {
  description = "Allow destroy to delete S3 bucket even with objects (true for test)"
  type        = bool
  default     = false
}

variable "proxy_config" {
  description = "LiteLLM proxy configuration (YAML map, mirrors config.yaml)"
  type        = any
  default     = {}
}

variable "tags" {
  description = "Common tags for all AWS resources"
  type        = map(string)
  default = {
    Project     = "LiteLLM"
    Environment = "production"
    ManagedBy   = "Terraform"
  }
}
