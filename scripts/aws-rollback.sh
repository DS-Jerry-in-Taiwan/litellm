#!/bin/bash
# =============================================================================
# LiteLLM AWS ECS Rollback Helper
# =============================================================================
# Rollback ECS service to the previous task definition revision.
# Reads cluster/service from Terraform outputs by default, with CLI overrides.
#
# Usage:
#   ./scripts/aws-rollback.sh <env> [--profile <aws_profile>]
#                               [--cluster <name>] [--service <name>]
#
# Arguments:
#   env           Environment name (used as Terraform workspace / tfvars path)
#   --profile     Optional AWS profile override (default: env name)
#   --cluster     Override: ECS cluster name (bypasses Terraform output)
#   --service     Override: ECS service name (bypasses Terraform output)
#
# Examples:
#   ./scripts/aws-rollback.sh office-mfa
#   ./scripts/aws-rollback.sh office-mfa --profile prod
#   ./scripts/aws-rollback.sh office-mfa --cluster my-cluster --service my-service
# =============================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'
error()   { echo -e "${RED}✗${NC} $1" >&2; exit 1; }
info()    { echo -e "${BLUE}ℹ${NC} $1"; }
success() { echo -e "${GREEN}✓${NC} $1"; }
warn()    { echo -e "${YELLOW}⚠${NC} $1"; }

show_usage() {
    cat <<EOF
Usage: $0 <env> [--profile <aws_profile>]
              [--cluster <name>] [--service <name>]

Arguments:
  env           Environment name (used as workspace/tfvars path)
  --profile     Optional AWS profile override (default: env name)
  --cluster     Override: ECS cluster name (bypasses Terraform output)
  --service     Override: ECS service name (bypasses Terraform output)

Examples:
  $0 office-mfa
  $0 office-mfa --profile prod
  $0 office-mfa --cluster my-cluster --service my-service
EOF
}

# ── Argument parsing ──────────────────────────────────────────────────────────
if [[ $# -lt 1 ]] || [[ "$1" == "--help" ]] || [[ "$1" == "-h" ]]; then
    show_usage
    exit 0
fi

ENV_NAME="$1"
shift

PROFILE="$ENV_NAME"  # default: AWS_PROFILE mirrors env name
CLUSTER=""
SERVICE=""
CLUSTER_OVERRIDE=""
SERVICE_OVERRIDE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --profile)
            PROFILE="$2"
            shift 2
            ;;
        --cluster)
            CLUSTER_OVERRIDE="$2"
            shift 2
            ;;
        --service)
            SERVICE_OVERRIDE="$2"
            shift 2
            ;;
        *)
            error "Unknown option: $1"
            ;;
    esac
done

# ── Paths ────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="$SCRIPT_DIR/../../deploy/aws/company-existing"
WORKSPACE="$ENV_NAME"

# ── Avoid external TF_WORKSPACE pollution ─────────────────────────────────────
unset TF_WORKSPACE

# ── Terraform init ───────────────────────────────────────────────────────────
info "Initializing Terraform (TF_DIR=$TF_DIR)..."
terraform -chdir="$TF_DIR" init

# ── Terraform workspace select (must exist — rollback never auto-creates) ─────
info "Selecting workspace: $WORKSPACE"
if ! terraform -chdir="$TF_DIR" workspace select "$WORKSPACE" 2>/dev/null; then
    error "Workspace '$WORKSPACE' does not exist. Run 'terraform-plan.sh $WORKSPACE' first to create it."
fi

# ── Resolve cluster/service ───────────────────────────────────────────────────
# CLI override takes priority over Terraform output; output is the default path.
if [[ -n "$CLUSTER_OVERRIDE" ]]; then
    CLUSTER="$CLUSTER_OVERRIDE"
    info "Using --cluster override: $CLUSTER"
elif [[ -n "$SERVICE_OVERRIDE" ]]; then
    SERVICE="$SERVICE_OVERRIDE"
    info "Using --service override: $SERVICE"
    # If only service is overridden, still need cluster from output or default
    if [[ -z "$CLUSTER" ]]; then
        CLUSTER=$(terraform -chdir="$TF_DIR" output -raw ecs_cluster_name 2>/dev/null) \
            || error "Failed to read 'ecs_cluster_name' from Terraform output. Provide --cluster explicitly."
        info "Resolved cluster from Terraform output: $CLUSTER"
    fi
else
    # Both from Terraform outputs
    CLUSTER=$(terraform -chdir="$TF_DIR" output -raw ecs_cluster_name 2>/dev/null) \
        || error "Failed to read 'ecs_cluster_name' from Terraform output. Provide --cluster explicitly."
    SERVICE=$(terraform -chdir="$TF_DIR" output -raw ecs_service_name 2>/dev/null) \
        || error "Failed to read 'ecs_service_name' from Terraform output. Provide --service explicitly."
    info "Resolved from Terraform outputs — cluster=$CLUSTER  service=$SERVICE"
fi

# ── Fetch current task definition from ECS ────────────────────────────────────
# Extract family AND revision from the ARN returned by describe-services.
TASK_DEF_ARN=$(AWS_PROFILE="$PROFILE" aws ecs describe-services \
    --cluster "$CLUSTER" \
    --services "$SERVICE" \
    --query 'services[0].taskDefinition' \
    --output text 2>/dev/null) \
    || error "Failed to describe ECS service '$SERVICE' in cluster '$CLUSTER'"

# Parse ARN format: arn:aws:ecs:<region>:<account>:task-definition/<family>:<revision>
# Example: arn:aws:ecs:ap-northeast-1:123456789:task-definition/litellm:12
FAMILY=$(echo "$TASK_DEF_ARN" | awk -F/ '{print $2}' | awk -F: '{print $1}')
CURRENT_REVISION=$(echo "$TASK_DEF_ARN" | awk -F: '{print $NF}')

if [[ -z "$FAMILY" ]] || [[ -z "$CURRENT_REVISION" ]]; then
    error "Could not parse task definition ARN: $TASK_DEF_ARN"
fi

PREVIOUS_REVISION=$((CURRENT_REVISION - 1))
if [[ "$PREVIOUS_REVISION" -lt 1 ]]; then
    error "No previous revision to rollback to (current: ${CURRENT_REVISION})"
fi

# ── Confirmation prompt ───────────────────────────────────────────────────────
echo ""
echo -e "${YELLOW}════════════════════════════════════════════════════════════════${NC}"
echo -e "${YELLOW}  ECS Rollback Confirmation${NC}"
echo -e "${YELLOW}════════════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "  ${BOLD}Environment:${NC}   $ENV_NAME"
echo -e "  ${BOLD}Workspace:${NC}    $WORKSPACE"
echo -e "  ${BOLD}AWS profile:${NC}  $PROFILE"
echo -e "  ${BOLD}Cluster:${NC}      $CLUSTER"
echo -e "  ${BOLD}Service:${NC}     $SERVICE"
echo -e "  ${BOLD}Task family:${NC} $FAMILY"
echo -e "  ${BOLD}Current rev:${NC} $CURRENT_REVISION"
echo -e "  ${BOLD}Rollback to:${NC} ${FAMILY}:${PREVIOUS_REVISION}"
echo ""
echo -e "${YELLOW}⚠  This will rollback ECS service '$SERVICE' in cluster '$CLUSTER'.${NC}"
echo ""
read -r -p "Type 'rollback ${ENV_NAME}' to continue: " confirm
echo ""

if [[ "$confirm" != "rollback ${ENV_NAME}" ]]; then
    info "Rollback cancelled by user"
    exit 1
fi

# ── Execute rollback ───────────────────────────────────────────────────────────
info "Rolling back service '$SERVICE' to ${FAMILY}:${PREVIOUS_REVISION}..."
AWS_PROFILE="$PROFILE" aws ecs update-service \
    --cluster "$CLUSTER" \
    --service "$SERVICE" \
    --task-definition "${FAMILY}:${PREVIOUS_REVISION}" \
    --force-new-deployment \
    --query 'service.serviceName' \
    --output text > /dev/null

info "Waiting for service to stabilise..."
AWS_PROFILE="$PROFILE" aws ecs wait services-stable \
    --cluster "$CLUSTER" \
    --services "$SERVICE"

success "Rollback complete — $SERVICE now running ${FAMILY}:${PREVIOUS_REVISION}"
