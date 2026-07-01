# =============================================================================
# Networking Module — VPC, Subnets, Security Groups, NAT Gateway
# =============================================================================

resource "aws_vpc" "main" {
  count = var.create_vpc ? 1 : 0

  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = merge(var.tags, { Name = "litellm-vpc" })
}

data "aws_vpc" "existing" {
  count = var.create_vpc ? 0 : 1

  id = var.existing_vpc_id
}

locals {
  vpc_id   = var.create_vpc ? aws_vpc.main[0].id : data.aws_vpc.existing[0].id
  vpc_cidr = var.create_vpc ? var.vpc_cidr : data.aws_vpc.existing[0].cidr_block
}

# ─────────────────────────────────────────────────────────────────────────────
# Internet Gateway
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_internet_gateway" "main" {
  count = var.create_vpc ? 1 : 0

  vpc_id = local.vpc_id

  tags = merge(var.tags, { Name = "litellm-igw" })
}

# ─────────────────────────────────────────────────────────────────────────────
# Public Subnets
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_subnet" "public" {
  count = var.create_vpc ? length(var.public_subnet_cidrs) : 0

  vpc_id                  = local.vpc_id
  cidr_block              = var.public_subnet_cidrs[count.index]
  availability_zone       = var.availability_zones[count.index]
  map_public_ip_on_launch = true

  tags = merge(var.tags, {
    Name = "litellm-public-subnet-${count.index + 1}"
    Tier = "Public"
  })
}

# ─────────────────────────────────────────────────────────────────────────────
# Private App Subnets (ECS tasks)
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_subnet" "private_app" {
  count = var.create_vpc ? length(var.private_app_subnet_cidrs) : 0

  vpc_id            = local.vpc_id
  cidr_block        = var.private_app_subnet_cidrs[count.index]
  availability_zone = var.availability_zones[count.index]

  tags = merge(var.tags, {
    Name = "litellm-private-app-subnet-${count.index + 1}"
    Tier = "Private App"
  })
}

# ─────────────────────────────────────────────────────────────────────────────
# Private Data Subnets (RDS, ElastiCache)
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_subnet" "private_data" {
  count = var.create_vpc ? length(var.private_data_subnet_cidrs) : 0

  vpc_id            = local.vpc_id
  cidr_block        = var.private_data_subnet_cidrs[count.index]
  availability_zone = var.availability_zones[count.index]

  tags = merge(var.tags, {
    Name = "litellm-private-data-subnet-${count.index + 1}"
    Tier = "Private Data"
  })
}

# ─────────────────────────────────────────────────────────────────────────────
# Elastic IP for NAT Gateway
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_eip" "nat" {
  count = var.create_vpc && var.enable_nat_gateway ? 1 : 0

  domain = "vpc"

  tags = merge(var.tags, { Name = "litellm-nat-eip" })
}

# ─────────────────────────────────────────────────────────────────────────────
# NAT Gateway
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_nat_gateway" "main" {
  count = var.create_vpc && var.enable_nat_gateway ? 1 : 0

  allocation_id = aws_eip.nat[0].id
  subnet_id     = aws_subnet.public[0].id

  tags = merge(var.tags, { Name = "litellm-nat" })

  depends_on = [aws_internet_gateway.main]
}

# ─────────────────────────────────────────────────────────────────────────────
# Route Tables
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_route_table" "public" {
  count = var.create_vpc ? 1 : 0

  vpc_id = local.vpc_id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main[0].id
  }

  tags = merge(var.tags, { Name = "litellm-public-rt" })
}

resource "aws_route_table" "private_app" {
  count = var.create_vpc ? 1 : 0

  vpc_id = local.vpc_id

  dynamic "route" {
    for_each = var.enable_nat_gateway ? [1] : []
    content {
      cidr_block     = "0.0.0.0/0"
      nat_gateway_id = aws_nat_gateway.main[0].id
    }
  }

  tags = merge(var.tags, { Name = "litellm-private-app-rt" })
}

# Route table for data subnets — no NAT needed (RDS/Redis are fully private)
resource "aws_route_table" "private_data" {
  count = var.create_vpc ? 1 : 0

  vpc_id = local.vpc_id

  # No default route — data resources are fully private and do not need internet
  tags = merge(var.tags, { Name = "litellm-private-data-rt" })
}

# ─────────────────────────────────────────────────────────────────────────────
# Route Table Associations
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_route_table_association" "public" {
  count = var.create_vpc ? length(var.public_subnet_cidrs) : 0

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public[0].id
}

resource "aws_route_table_association" "private_app" {
  count = var.create_vpc ? length(var.private_app_subnet_cidrs) : 0

  subnet_id      = aws_subnet.private_app[count.index].id
  route_table_id = aws_route_table.private_app[0].id
}

resource "aws_route_table_association" "private_data" {
  count = var.create_vpc ? length(var.private_data_subnet_cidrs) : 0

  subnet_id      = aws_subnet.private_data[count.index].id
  route_table_id = aws_route_table.private_data[0].id
}

# ─────────────────────────────────────────────────────────────────────────────
# Security Groups — created only in new VPC mode; use existing_* inputs in existing VPC mode
# ─────────────────────────────────────────────────────────────────────────────

# ALB security group: allows HTTPS 443 from internet + port 4000 to ECS
resource "aws_security_group" "alb" {
  count       = var.create_vpc ? 1 : 0
  name        = "litellm-alb-sg"
  description = "Security group for the LiteLLM ALB. Allows HTTPS 443 from internet."
  vpc_id      = local.vpc_id

  tags = merge(var.tags, { Name = "litellm-alb-sg" })
}

resource "aws_vpc_security_group_ingress_rule" "alb_https" {
  count             = var.create_vpc ? 1 : 0
  security_group_id = aws_security_group.alb[0].id
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
  description       = "Allow HTTPS 443 from internet"
}

resource "aws_vpc_security_group_egress_rule" "alb_to_ecs" {
  count                        = var.create_vpc ? 1 : 0
  security_group_id            = aws_security_group.alb[0].id
  referenced_security_group_id = aws_security_group.ecs[0].id
  from_port                    = 4000
  to_port                      = 4000
  ip_protocol                  = "tcp"
  description                  = "Allow ALB to forward to ECS on port 4000"
}

# ECS security group: allows 4000 from ALB only
resource "aws_security_group" "ecs" {
  count       = var.create_vpc ? 1 : 0
  name        = "litellm-ecs-sg"
  description = "Security group for LiteLLM ECS tasks. Allows port 4000 from ALB only."
  vpc_id      = local.vpc_id

  tags = merge(var.tags, { Name = "litellm-ecs-sg" })
}

resource "aws_vpc_security_group_ingress_rule" "ecs_from_alb" {
  count                        = var.create_vpc ? 1 : 0
  security_group_id            = aws_security_group.ecs[0].id
  referenced_security_group_id = aws_security_group.alb[0].id
  from_port                    = 4000
  to_port                      = 4000
  ip_protocol                  = "tcp"
  description                  = "Allow traffic from ALB on port 4000"
}

resource "aws_vpc_security_group_egress_rule" "ecs_all" {
  count             = var.create_vpc ? 1 : 0
  security_group_id = aws_security_group.ecs[0].id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1" # All protocols
  description       = "Allow all outbound traffic (for provider API calls, ECR pull, etc.)"
}

# Data security group: allows ECS on 5432 (PostgreSQL) and 6379 (Redis)
resource "aws_security_group" "data" {
  count       = var.create_vpc ? 1 : 0
  name        = "litellm-data-sg"
  description = "Security group for RDS PostgreSQL and ElastiCache. Allows ECS on 5432 and 6379."
  vpc_id      = local.vpc_id

  tags = merge(var.tags, { Name = "litellm-data-sg" })
}

resource "aws_vpc_security_group_ingress_rule" "ecs_to_rds" {
  count                        = var.create_vpc ? 1 : 0
  security_group_id            = aws_security_group.data[0].id
  referenced_security_group_id = aws_security_group.ecs[0].id
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
  description                  = "Allow ECS to connect to RDS PostgreSQL on 5432"
}

resource "aws_vpc_security_group_ingress_rule" "ecs_to_redis" {
  count                        = var.create_vpc ? 1 : 0
  security_group_id            = aws_security_group.data[0].id
  referenced_security_group_id = aws_security_group.ecs[0].id
  from_port                    = 6379
  to_port                      = 6379
  ip_protocol                  = "tcp"
  description                  = "Allow ECS to connect to ElastiCache Redis on 6379"
}