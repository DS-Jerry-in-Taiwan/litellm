#!/bin/bash
# =============================================================================
# LiteLLM AWS ECS Deploy Helper
# =============================================================================
# Deploy a specific image tag to ECS service.
#
# Usage:
#   ./scripts/aws-deploy.sh <image_tag> [cluster] [service]
#
# Examples:
#   ./scripts/aws-deploy.sh abc1234
#   ./scripts/aws-deploy.sh abc1234 litellm litellm
# =============================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'
log_info()    { echo -e "${BLUE}ℹ${NC} $1"; }
log_success() { echo -e "${GREEN}✓${NC} $1"; }
log_error()   { echo -e "${RED}✗${NC} $1" >&2; }

IMAGE_TAG="${1:-}"
CLUSTER="${2:-litellm}"
SERVICE="${3:-litellm}"

if [ -z "$IMAGE_TAG" ]; then
    log_error "Usage: $0 <image_tag> [cluster] [service]"
    exit 1
fi

log_info "Deploying image tag: ${IMAGE_TAG} to cluster=${CLUSTER} service=${SERVICE}"

# Register new task definition with updated image
TASK_DEF=$(aws ecs describe-task-definition \
    --task-definition "$SERVICE" \
    --query 'taskDefinition' \
    --output json)

NEW_TASK_DEF=$(echo "$TASK_DEF" | \
    jq --arg TAG "$IMAGE_TAG" \
    '.containerDefinitions[0].image |= sub(":.*"; ":" + $TAG) | 
     {family, taskRoleArn, executionRoleArn, networkMode, containerDefinitions, volumes, requiresCompatibilities, cpu, memory}' )

NEW_REVISION=$(aws ecs register-task-definition \
    --cli-input-json "$NEW_TASK_DEF" \
    --query 'taskDefinition.revision' \
    --output text)

log_success "Registered task definition revision: ${NEW_REVISION}"

# Update service
aws ecs update-service \
    --cluster "$CLUSTER" \
    --service "$SERVICE" \
    --task-definition "${SERVICE}:${NEW_REVISION}" \
    --force-new-deployment \
    --query 'service.serviceName' \
    --output text > /dev/null

log_info "Waiting for service stable..."
aws ecs wait services-stable --cluster "$CLUSTER" --services "$SERVICE"
log_success "Service stable: ${SERVICE}"

# Optional: run smoke test
if [ -f "./smoke_test.sh" ]; then
    log_info "Running smoke test..."
    ALB_DNS=$(aws elbv2 describe-load-balancers \
        --names litellm-alb \
        --query 'LoadBalancers[0].DNSName' \
        --output text)
    ./smoke_test.sh "http://${ALB_DNS}" && log_success "Smoke test PASS" || log_error "Smoke test FAIL"
fi
