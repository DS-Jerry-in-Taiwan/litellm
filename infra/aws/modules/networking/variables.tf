# =============================================================================
# Networking Module Variables
# =============================================================================

variable "create_vpc" {
  description = "Whether to create a new VPC. Set to false to use an existing VPC."
  type        = bool
}

variable "existing_vpc_id" {
  description = "Existing VPC ID when create_vpc = false."
  type        = string
  default     = ""
}

variable "existing_public_subnet_ids" {
  description = "Existing public subnet IDs when create_vpc = false. Must have at least 2 for HA."
  type        = list(string)
  default     = []
}

variable "existing_private_app_subnet_ids" {
  description = "Existing private app subnet IDs (for ECS tasks) when create_vpc = false."
  type        = list(string)
  default     = []
}

variable "existing_private_data_subnet_ids" {
  description = "Existing private data subnet IDs (for RDS/ElastiCache) when create_vpc = false."
  type        = list(string)
  default     = []
}

variable "existing_vpc_alb_sg_id" {
  description = "Existing ALB security group ID when create_vpc = false."
  type        = string
  default     = ""
}

variable "existing_vpc_ecs_sg_id" {
  description = "Existing ECS tasks security group ID when create_vpc = false."
  type        = string
  default     = ""
}

variable "existing_vpc_data_sg_id" {
  description = "Existing data-layer security group ID (RDS/Redis) when create_vpc = false."
  type        = string
  default     = ""
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC (used when create_vpc = true)."
  type        = string
  default     = "10.0.0.0/16"
}

variable "availability_zones" {
  description = "List of availability zones."
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b"]
}

variable "public_subnet_cidrs" {
  description = "CIDR blocks for public subnets."
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24"]
}

variable "private_app_subnet_cidrs" {
  description = "CIDR blocks for private app subnets."
  type        = list(string)
  default     = ["10.0.11.0/24", "10.0.12.0/24"]
}

variable "private_data_subnet_cidrs" {
  description = "CIDR blocks for private data subnets."
  type        = list(string)
  default     = ["10.0.21.0/24", "10.0.22.0/24"]
}

variable "enable_nat_gateway" {
  description = "Whether to create NAT Gateway for ECS outbound access."
  type        = bool
  default     = true
}

variable "tags" {
  description = "Tags to apply to all resources."
  type        = map(string)
  default     = {}
}