# =============================================================================
# AWS ECS Fargate Infrastructure — Phase 2 Skeleton
# =============================================================================
# Purpose: IaC skeleton for running the LiteLLM custom image on AWS ECS Fargate.
#
# IMPORTANT — This is a planning/skeleton artifact only:
#   ❌ Does NOT provision or deploy any AWS resources.
#   ❌ Does NOT contain real AWS account IDs, access keys, secrets, or passwords.
#   ❌ Does NOT run terraform apply.
#
# Before any real deployment:
#   ✅ Human HITL approval required for AWS account, region, cost envelope.
#   ✅ image push to ECR requires separate approval.
#   ✅ Delegated to agent-releaser for any promotion/release workflow.
#
# Design decisions:
#   - Reuses root Dockerfile / custom LiteLLM image (Phase 1 image parity).
#   - Secrets injected via AWS Secrets Manager / SSM Parameter Store into ECS.
#   - Local Mode (docker compose) remains unchanged.
#
# =============================================================================

## Architecture Overview

```
Internet → ALB (HTTPS 443) → ECS Fargate (LiteLLM :4000)
                              │
                              ├── RDS PostgreSQL (private subnets)
                              ├── ElastiCache Redis/Valkey (private subnets)
                              ├── CloudWatch Logs
                              ├── ECR (image pull)
                              └── Secrets Manager / SSM (secrets injection)
```

### Key design decisions

| Component       | AWS Service                  | Notes                                              |
|-----------------|------------------------------|----------------------------------------------------|
| Compute         | ECS Fargate                  | No EC2 ops burden; same custom image as Local Mode |
| Registry        | Amazon ECR                   | Private repo; ECR image_tag_mutability=IMMUTABLE   |
| Database        | Amazon RDS PostgreSQL        | Replaces local postgres container                  |
| Redis           | Amazon ElastiCache Redis/Valkey | Shared RPM/health cache for multi-task ECS       |
| Secrets         | AWS Secrets Manager / SSM    | LITELLM_MASTER_KEY, DATABASE_URL, provider keys   |
| Load Balancer   | Application Load Balancer    | HTTPS listener; health check on /health/liveliness |
| Observability   | CloudWatch Logs + optional AMP/Grafana | Replaces local Prometheus           |

### Required env / secrets mapping

| Name                  | Source in current repo       | AWS source                          |
|-----------------------|------------------------------|-------------------------------------|
| `DATABASE_URL`        | `config.yaml`, `.env.example`| Secrets Manager / SSM Parameter     |
| `LITELLM_MASTER_KEY`  | `config.yaml`, `.env.example`| Secrets Manager                     |
| `LITELLM_SALT_KEY`    | `.env.example`, `compose.yaml`| Secrets Manager                    |
| `REDIS_HOST`          | `config.yaml`, `.env.example`| ECS env from ElastiCache endpoint   |
| `REDIS_PORT`          | `config.yaml`, `.env.example`| ECS env, default `6379`             |
| `REDIS_PASSWORD`      | `config.yaml`, `.env.example`| Secrets Manager or empty for dev    |
| Provider keys         | `.env.example`, `config.yaml.example` | Secrets Manager              |

### HITL / Releaser boundaries (Phase 2 prd-like)

The following actions are **NOT automated** and require Human HITL approval
plus agent-releaser coordination before execution:

| Action | Who approves | Who executes |
|--------|-------------|-------------|
| `terraform apply` (any environment) | Human + cost envelope owner | Infra team |
| ECR image push | Human + image digest approver | Releaser agent |
| ECS service update (new task def) | Human | Releaser agent |
| Changing `image_tag` in ECS | Releaser (must pin new tag first) | Releaser agent |
| Updating `acm_certificate_arn` for HTTPS | Human | Infra team |
| Enabling `rds_multi_az` (cost impact) | Human + cost owner | Infra team |

**Phase 2 produces only IaC skeleton. No AWS resources are created or deployed.**

### Image digest / tag policy

- The ECR repository uses `image_tag_mutability = IMMUTABLE`.
- ECS task definition MUST NOT reference `:latest`.
- The `image_tag` Terraform variable is validated to reject `latest`.
- A pinned tag (e.g. `v20260625-image-parity`) or full image digest
  (`sha256:abc123...`) is required before ECS deployment.
- The Releaser is responsible for pinning a stable tag/digest before promotion.
- Docker Compose continues to use `:local` tag; ECS promotion uses a pinned ECR tag.

### Config delivery policy

- **Local mode (Docker Compose)**: `config.yaml` is a bind mount (`./config.yaml:/app/config.yaml:ro`).
- **AWS ECS Fargate**: `config.yaml` is baked into the Docker image (`COPY config.yaml /app/config.yaml`).
  - This is intentional because ECS tasks cannot use host bind mounts.
  - To update config in ECS: rebuild image → push to ECR → update ECS service.
  - Secrets (e.g. `LITELLM_MASTER_KEY`, `DATABASE_URL`) are injected via
    AWS Secrets Manager / SSM Parameter Store into ECS environment variables.
  - Local Compose can still override the baked-in `config.yaml` with a volume mount.

### `/metrics` patch policy

- LiteLLM 1.89.x / 1.90.x has a regression where `app.mount('/metrics', make_asgi_app())`
  does not properly register the `/metrics` endpoint, returning HTTP 404.
- The `patch_metrics.py` workaround is **mandatory and non-removable** without:
  1. Upstream LiteLLM confirmation the regression is fixed, AND
  2. Architect + QA + Human HITL explicit approval to remove.
- `patch_metrics.py` is baked into the image and runs at container start
  (before LiteLLM import) via `litellm-entrypoint.sh`.
- Multi-path fallback: supports both `.venv`-bundled and legacy proxy_server.py paths.
- Fail-fast behavior: if neither candidate path is found, the container exits
  with a sanitized error listing the searched paths.

### NAT Gateway / VPC endpoint trade-off

ECS tasks run in private subnets and have no direct internet access by default.

| Option | Use case | Cost |
|--------|----------|------|
| **NAT Gateway** (default: `enable_nat_gateway = true`) | Full outbound internet for ECS tasks (pull images, call provider APIs) | ~$30-45/month + egress |
| **VPC Endpoints** (disable NAT) | ECR image pull (via VPC endpoint), provider APIs via AWS PrivateLink | Lower; depends on endpoint count |
| **No NAT, no endpoints** | ECS can only reach AWS services with private endpoints; provider calls will fail | Lowest |

If `enable_nat_gateway = false`:
- Ensure VPC Endpoints exist for ECR and any AWS services used.
- Provider API calls (OpenAI, Anthropic, etc.) require NAT Gateway or a
  proxy/PrivateLink endpoint in the VPC.
- The `terraform plan` will succeed with no NAT route when disabled.

### Security baseline

- ✅ RDS PostgreSQL in private subnets; not publicly accessible.
- ✅ ElastiCache Redis/Valkey in private subnets; not publicly accessible.
- ✅ ECS tasks in private subnets; only ALB has public ingress (HTTPS 443).
- ✅ All secrets stored in AWS Secrets Manager / SSM; never in code or Git.
- ✅ ALB TLS termination required for production (ACM certificate ARN).
- ✅ CloudWatch log group for ECS container logs.

### Cost warning

The following AWS resources incur charges even when idle:

- Application Load Balancer (hourly + LCU).
- NAT Gateway (if enabled for ECS outbound internet access).
- RDS PostgreSQL (instance hours + storage + backups).
- ElastiCache Redis/Valkey (node hours + storage).
- CloudWatch Logs (ingestion + storage).

Use the production configuration (2+ ECS tasks, larger RDS instance, Multi-AZ) only when cost envelope is approved.

---

## Prerequisites

1. **AWS account + IAM user/role** with permissions to create the resources defined in this Terraform.
2. **AWS region** selected (set in `terraform.tfvars` or via environment).
3. **Docker image** built from the root `Dockerfile` and pushed to the ECR repository created by this Terraform. See "Future image push flow" below.
4. **ACM certificate** (optional for production) for HTTPS listener; can use placeholder for dev.
5. **Domain name** (optional) for production ALB DNS; uses AWS-provided default DNS for dev.
6. **Terraform ≥ 1.6** installed locally.

---

## Directory structure

```
infra/aws/
├── README.md                 ← This file
├── versions.tf               ← Terraform version constraints
├── providers.tf              ← AWS provider configuration
├── variables.tf              ← Input variables with descriptions
├── outputs.tf               ← Non-secret outputs
├── main.tf                  ← Root module orchestration
├── terraform.tfvars.example ← Example variable values (no real secrets)
└── modules/
    ├── networking/           ← VPC, subnets, security groups, NAT GW
    │   ├── main.tf
    │   ├── variables.tf
    │   └── outputs.tf
    ├── ecs/                 ← ECS cluster, task definition, service, ALB
    │   ├── main.tf
    │   ├── variables.tf
    │   └── outputs.tf
    ├── ecr/                 ← ECR repository + lifecycle policy
    │   ├── main.tf
    │   ├── variables.tf
    │   └── outputs.tf
    └── data/                ← RDS, ElastiCache, Secrets Manager, SSM
        ├── main.tf
        ├── variables.tf
        └── outputs.tf
```

---

## Usage

### 1. Copy and edit variables

```bash
cp infra/aws/terraform.tfvars.example infra/aws/terraform.tfvars
# Edit terraform.tfvars with your values (no real secrets)
```

### 1a. New VPC vs. Existing VPC mode

The Terraform variable `create_vpc` controls whether to create a new VPC or use an existing one:

**New VPC mode (`create_vpc = true`, default):**
All networking resources (VPC, subnets, NAT Gateway, security groups) are created by Terraform. No additional variables needed.

**Existing VPC mode (`create_vpc = false`):**
Set `create_vpc = false` and provide all of the following variables:

```bash
# In terraform.tfvars:
create_vpc = false

# Required: VPC ID
existing_vpc_id = "vpc-xxxxxxxxxxxxx"

# Required: Subnet IDs (must be in different AZs)
existing_public_subnet_ids       = ["subnet-0abcdef1", "subnet-0abcdef2"]
existing_private_app_subnet_ids  = ["subnet-0abcdef3", "subnet-0abcdef4"]
existing_private_data_subnet_ids = ["subnet-0abcdef5", "subnet-0abcdef6"]

# Required: Pre-configured security group IDs
#   ALB SG must allow HTTPS 443 from internet and port 4000 → ECS SG
#   ECS SG must allow port 4000 from ALB SG
#   Data SG must allow ECS on 5432 (PostgreSQL) and 6379 (Redis)
existing_vpc_alb_sg_id   = "sg-0abcdef7"
existing_vpc_ecs_sg_id   = "sg-0abcdef8"
existing_vpc_data_sg_id  = "sg-0abcdef9"
```

> ⚠️ **Security group prerequisites for existing VPC mode:** Your existing security groups must already have the correct ingress/egress rules configured, or Terraform will fail at the plan stage. Alternatively, set `create_vpc = true` to let Terraform manage the security groups as well.

### 2. Initialize Terraform (no backend = safe for review)

```bash
terraform -chdir=infra/aws init -backend=false
```

### 3. Format check

```bash
terraform -chdir=infra/aws fmt -check -recursive
```

### 4. Validate

```bash
terraform -chdir=infra/aws validate
```

### 5. Plan (review only — does NOT apply)

```bash
terraform -chdir=infra/aws plan -var-file=infra/aws/terraform.tfvars
```

### 6. Apply (requires separate Human HITL approval)

```bash
terraform -chdir=infra/aws apply -var-file=infra/aws/terraform.tfvars
```

---

## Future image push flow (documentation only)

> ⚠️ These are **planned future steps**, not executed in Phase 2. Requires separate Human HITL approval.

```bash
# 1. Authenticate Docker to ECR
aws ecr get-login-password --region us-east-1 | \
  docker login --username AWS --password-stdin <ecr-repo-url>

# 2. Tag the local image built from root Dockerfile
docker tag litellm-deployment-template:local \
  <ecr-repo-url>/litellm-deployment-template:latest

# 3. Push to ECR
docker push <ecr-repo-url>/litellm-deployment-template:latest
```

Local Mode build: `docker build -t litellm-deployment-template:local .`
AWS Mode build: same `Dockerfile` → push to ECR → ECS pulls from ECR.

---

## AWS smoke test (after deployment, separate HITL approval required)

```bash
# Set ALB DNS from Terraform output
export LITELLM_BASE_URL="https://<alb_dns_name>"
export LITELLM_API_KEY="<LITELLM_MASTER_KEY_from_Secrets_Manager>"

# Basic health check
./smoke_test.sh

# Provider-backed chat test (requires TEST_MODEL to be created via Admin UI first)
TEST_MODEL=<existing-model> RUN_CHAT_TEST=true ./smoke_test.sh

# User RPM test (requires TEST_MODEL)
TEST_MODEL=<existing-model> RUN_PROVIDER_CALLS=false ./test_user_rpm.sh
```

---

## Phase 2 status — prd-like hardening complete

**Phase 2 produces a prd-like IaC skeleton + static validation. No AWS resources are created or deployed.**

- ❌ No `terraform apply` executed.
- ❌ No image pushed to ECR.
- ❌ No RDS, ElastiCache, ECS, or ALB provisioned.
- ❌ No DNS or TLS certificates configured.
- ✅ ECS task definition no longer hardcodes `:latest`; requires pinned `image_tag`.
- ✅ NAT Gateway route is conditional; `terraform plan` succeeds when disabled.
- ✅ SSM provider key placeholder removed; controlled by `create_ssm_parameter_openai_key`.
- ✅ ECR repository uses `IMMUTABLE` tag mutability.
- ✅ `patch_metrics.py` supports multi-path and fail-fast.
- ✅ `config.yaml` baked into image for ECS mode.
- ✅ `Dockerfile` base image pinned annotation added (Releaser responsibility).

Deployment/promotion requires separate Human HITL approval + agent-releaser coordination.

### DATABASE_URL pre-population checkpoint

`aws_secretsmanager_secret.database_url` is created by Terraform, but its **value is NOT
automatically set**. Before the ECS task can start, the secret must be populated:

```bash
# After terraform apply completes, populate the DATABASE_URL secret:
aws secretsmanager put-secret-value \
  --secret-id "litellm/database-url" \
  --secret-string "postgresql://litellm_admin:<RDS_PASSWORD>@<RDS_ENDPOINT>:5432/litellm"
```

The RDS endpoint is available from `terraform output rds_endpoint` after apply.
This is a **manual pre-deploy checkpoint** — do not skip it or the ECS task will fail to start.

---

## References

- [LiteLLM deployment docs](https://docs.litellm.ai/docs/proxy/deploy)
- [AWS ECS Fargate documentation](https://docs.aws.amazon.com/AmazonECS/)
- [Terraform AWS provider](https://registry.terraform.io/providers/hashicorp/aws/latest/docs)
- [AWS ECS + ALB health check best practices](https://docs.aws.amazon.com/AmazonECS/)