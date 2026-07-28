#!/bin/bash
# =============================================================================
# LiteLLM AWS Terraform Plan Helper
# =============================================================================
# Run 'terraform plan' for a given environment workspace.
# Produces both binary plan artifact and text plan for review.
#
# Usage:
#   ./scripts/aws/terraform-plan.sh <env> <image_tag> [--profile <aws_profile>]
#
# Arguments:
#   env           Environment name (used as workspace name and for tfvars path)
#   image_tag     Immutable image tag or digest (must NOT be 'latest')
#   --profile     Optional AWS profile override (default: env name)
#
# Example:
#   ./scripts/aws/terraform-plan.sh office-mfa abc1234 --profile office-mfa
#   ./scripts/aws/terraform-plan.sh dev v1.2.3
#
# Guards:
#   - Account allowlist validation
#   - Workspace existence check (no auto-create)
#   - Latest image tag blocked
#   - Missing tfvars blocked
#   - Context display before plan
#   - Binary + text plan artifact saved
# =============================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'
error()   { echo -e "${RED}✗${NC} $1" >&2; exit 1; }
info()    { echo -e "${BLUE}ℹ${NC} $1"; }
success() { echo -e "${GREEN}✓${NC} $1"; }
warn()    { echo -e "${YELLOW}⚠${NC} $1"; }

show_usage() {
    cat <<EOF
Usage: $0 <env> <image_tag> [--profile <aws_profile>]

Arguments:
  env           Environment name (used as workspace name and for tfvars path)
  image_tag     Immutable image tag or digest (must NOT be 'latest')
  --profile     Optional AWS profile override (default: env name)

Example:
  $0 office-mfa abc1234 --profile office-mfa
  $0 dev v1.2.3

Guards:
  - Account allowlist validation (office-mfa=132815414471, dev=887678037646)
  - Workspace existence check (no auto-create typo workspace)
  - Latest image tag blocked
  - Missing tfvars blocked
  - Binary + text plan artifact saved to plans/
EOF
}

# ── Argument parsing ──────────────────────────────────────────────────────────
if [[ $# -lt 2 ]] || [[ "$1" == "--help" ]] || [[ "$1" == "-h" ]]; then
    show_usage
    exit 0
fi

ENV_NAME="$1"
IMAGE_TAG="$2"
shift 2

PROFILE="$ENV_NAME"  # default: AWS_PROFILE mirrors env name

while [[ $# -gt 0 ]]; do
    case "$1" in
        --profile)
            PROFILE="$2"
            shift 2
            ;;
        *)
            error "Unknown option: $1"
            ;;
    esac
done

# ── Guard: no latest ──────────────────────────────────────────────────────────
if [[ "$IMAGE_TAG" == "latest" ]]; then
    error "image_tag must NOT be 'latest'. Use a pinned version tag or digest."
fi

# ── Paths ────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="$SCRIPT_DIR/../../deploy/aws/company-existing"
TFVARS="$TF_DIR/envs/${ENV_NAME}.tfvars"
WORKSPACE="$ENV_NAME"

# ── Guard: tfvars must exist ──────────────────────────────────────────────────
if [[ ! -f "$TFVARS" ]]; then
    error "tfvars not found: $TFVARS"$'\n'"Copy 'envs/${ENV_NAME}.tfvars.example' to 'envs/${ENV_NAME}.tfvars' and fill real values."
fi

# ── Load account helpers ───────────────────────────────────────────────────────
source "$SCRIPT_DIR/terraform-accounts.sh"

# ── Guard: account allowlist ───────────────────────────────────────────────────
info "Validating AWS account for environment '$ENV_NAME'..."
if ! validate_account "$ENV_NAME" "$PROFILE"; then
    error "Account validation failed. Aborting plan to prevent cross-account operations."
fi

# ── Guard: workspace must exist (no auto-create) ────────────────────────────────
info "Validating workspace '$WORKSPACE' exists..."
if ! validate_workspace "$TF_DIR" "$WORKSPACE" "$ENV_NAME"; then
    error "Workspace '$WORKSPACE' does not exist. Cannot auto-create. Contact Releaser/Human to approve workspace creation."
fi

# ── Avoid external TF_WORKSPACE pollution ─────────────────────────────────────
unset TF_WORKSPACE

# ── Display context ───────────────────────────────────────────────────────────
display_context "$ENV_NAME" "$PROFILE" "$TF_DIR" "$WORKSPACE" "$TFVARS"

# ── Terraform init ───────────────────────────────────────────────────────────
info "Initializing Terraform (TF_DIR=$TF_DIR)..."
terraform -chdir="$TF_DIR" init

# ── Select workspace (must already exist per guard above) ────────────────────
info "Selecting workspace: $WORKSPACE"
terraform -chdir="$TF_DIR" workspace select "$WORKSPACE"

# ── Generate timestamped plan artifact paths ───────────────────────────────────
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
PLAN_DIR="$TF_DIR/plans"
mkdir -p "$PLAN_DIR"
BINARY_PLAN="$PLAN_DIR/tfplan-${ENV_NAME}-${TIMESTAMP}.tfplan"
TEXT_PLAN="${BINARY_PLAN}.txt"

info "Plan artifacts will be saved to:"
info "  Binary: $BINARY_PLAN"
info "  Text:   $TEXT_PLAN"

# ── Terraform plan (save binary artifact) ────────────────────────────────────
info "Running terraform plan..."
info "  env=$ENV_NAME  workspace=$WORKSPACE  image_tag=$IMAGE_TAG  profile=$PROFILE"

PLAN_OUTPUT=$(AWS_PROFILE="$PROFILE" terraform -chdir="$TF_DIR" plan \
    -var-file="$TFVARS" \
    -var="image_tag=$IMAGE_TAG" \
    -out="$BINARY_PLAN" 2>&1) \
    || {
        echo "$PLAN_OUTPUT" | tail -20
        error "Terraform plan failed. Check errors above."
    }

# Save text plan
info "Saving text plan to $TEXT_PLAN..."
terraform -chdir="$TF_DIR" show -no-color "$BINARY_PLAN" > "$TEXT_PLAN"

# ── Check for destructive operations ──────────────────────────────────────────
info "Checking plan for destructive operations..."
PLAN_SUMMARY=$(terraform -chdir="$TF_DIR" show -no-color "$BINARY_PLAN" 2>&1 | head -30)

if is_destructive_plan "$PLAN_SUMMARY"; then
    local destructiveness
    destructiveness=$(describe_plan_destructiveness "$PLAN_SUMMARY")
    warn "DESTRUCTIVE OPERATIONS DETECTED in plan!"
    warn "Status: $destructiveness"
    echo ""
    echo "$PLAN_SUMMARY" | grep -iE "(Plan:|must be replaced|-/+)" | head -10
    echo ""
    warn "This plan contains destroy/replace operations. Human HITL required before apply."
    warn "Plan artifacts saved but apply is BLOCKED until approved."
else
    success "Plan contains no destroy/replace operations."
fi

success "Plan complete for env=$ENV_NAME"
echo ""
echo "=== Plan Artifacts ==="
echo "  Binary plan: $BINARY_PLAN"
echo "  Text plan:   $TEXT_PLAN"
echo "  Generated:   $(date -r "$BINARY_PLAN" '+%Y-%m-%d %H:%M:%S')"
echo ""
echo "IMPORTANT: Review text plan before applying. Apply only with approved binary plan."
