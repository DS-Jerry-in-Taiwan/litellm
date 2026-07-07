#!/bin/bash
# =============================================================================
# LiteLLM AWS ECS Rollback Helper
# =============================================================================
# Rollback ECS service to the previous task definition revision.
#
# Usage:
#   ./scripts/aws-rollback.sh [cluster] [service]
#
# Examples:
#   ./scripts/aws-rollback.sh
#   ./scripts/aws-rollback.sh litellm litellm
# =============================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'
log_info()    { echo -e "${BLUE}ℹ${NC} $1"; }
log_success() { echo -e "${GREEN}✓${NC} $1"; }
log_error()   { echo -e "${RED}✗${NC} $1" >&2; }

CLUSTER="${1:-litellm}"
SERVICE="${2:-litellm}"

CURRENT_REVISION=$(aws ecs describe-services \
    --cluster "$CLUSTER" \
    --services "$SERVICE" \
    --query 'services[0].taskDefinition' \
    --output text | awk -F: '{print $NF}')

PREVIOUS_REVISION=$((CURRENT_REVISION - 1))

if [ "$PREVIOUS_REVISION" -lt 1 ]; then
    log_error "No previous revision to rollback to (current: ${CURRENT_REVISION})"
    exit 1
fi

echo -e "${YELLOW}⚠  Current revision: ${CURRENT_REVISION}${NC}"
echo -e "${YELLOW}⚠  Rollback to:      ${PREVIOUS_REVISION}${NC}"
read -r -p "Continue? (y/N) " confirm
if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
    log_info "Rollback cancelled"
    exit 0
fi

aws ecs update-service \
    --cluster "$CLUSTER" \
    --service "$SERVICE" \
    --task-definition "${SERVICE}:${PREVIOUS_REVISION}" \
    --force-new-deployment \
    --query 'service.serviceName' \
    --output text > /dev/null

log_info "Waiting for service stable..."
aws ecs wait services-stable --cluster "$CLUSTER" --services "$SERVICE"
log_success "Rollback complete to revision ${PREVIOUS_REVISION}"
