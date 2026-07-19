#!/bin/bash
# =============================================================================
# LiteLLM AWS Terraform Apply Helper
# =============================================================================
# Apply a pre-generated terraform plan artifact.
# This script MUST be used after terraform-plan.sh has generated a reviewed plan.
#
# Usage:
#   ./scripts/aws/terraform-apply.sh <env> <image_tag> [--profile <aws_profile>]
#              [--plan <path_to_binary_plan>]
#
# Arguments:
#   env           Environment name (used as workspace name and for tfvars path)
#   image_tag     Immutable image tag or digest (must NOT be 'latest')
#   --profile     Optional AWS profile override (default: env name)
#   --plan        Path to binary plan artifact (must be HITL-reviewed for Phase 4 apply)
#
# Workflow:
#   1. Validate environment and account
#   2. Find or use specified binary plan artifact
#   3. Review plan summary for destroy/replace operations
#   4. Require Human HITL confirmation if destroy/replace found
#   5. Apply the binary plan artifact
#
# Example:
#   ./scripts/aws/terraform-apply.sh office-mfa abc1234 --profile office-mfa
#   ./scripts/aws/terraform-apply.sh office-mfa abc1234 --plan plans/tfplan-office-mfa-20260718-120000.tfplan
#
# IMPORTANT: When no --plan is specified, the script auto-finds the latest matching
#   plan artifact. This is a DEV CONVENIENCE ONLY. For Phase 4 / HITL production
#   apply, you MUST use --plan to specify a specific HITL-reviewed binary plan.
# =============================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'
error()   { echo -e "${RED}x${NC} $1" >&2; exit 1; }
info()    { echo -e "${BLUE}i${NC} $1"; }
success() { echo -e "${GREEN}✓${NC} $1"; }
warn()    { echo -e "${YELLOW}!${NC} $1"; }

show_usage() {
    cat <<EOF
Usage: $0 <env> <image_tag> [--profile <aws_profile>] [--plan <path_to_binary_plan>]

Arguments:
  env           Environment name (used as workspace name and for tfvars path)
  image_tag     Immutable image tag or digest (must NOT be 'latest')
  --profile     Optional AWS profile override (default: env name)
  --plan        Path to binary plan artifact (must be HITL-reviewed for Phase 4 apply)

Workflow:
  1. Validate environment and account
  2. Find or use specified binary plan artifact
  3. Review plan summary for destroy/replace operations
  4. Require Human HITL confirmation if destroy/replace found
  5. Apply the binary plan artifact

Example:
  $0 office-mfa abc1234 --profile office-mfa
  $0 office-mfa abc1234 --plan plans/tfplan-office-mfa-20260718-120000.tfplan

IMPORTANT: When no --plan is specified, the script auto-finds the latest matching
  plan artifact. This is a DEV CONVENIENCE ONLY. For Phase 4 / HITL production
  apply, you MUST use --plan to specify a specific HITL-reviewed binary plan.

Guards:
  - Account allowlist validation
  - Workspace existence check + explicit select before apply
  - Latest image tag blocked
  - Missing tfvars blocked
  - Plan artifact basename must match tfplan-\${ENV_NAME}-*.tfplan
  - Auto-found latest plan is DEV CONVENIENCE ONLY; Phase 4 must use --plan
  - Destroy/replace operations require explicit HITL
EOF
}

# -- Argument parsing -----------------------------------------------------------
if [[ $# -lt 2 ]] || [[ "$1" == "--help" ]] || [[ "$1" == "-h" ]]; then
    show_usage
    exit 0
fi

ENV_NAME="$1"
IMAGE_TAG="$2"
shift 2

PROFILE="$ENV_NAME"  # default: AWS_PROFILE mirrors env name
PLAN_PATH=""          # Binary plan artifact path

while [[ $# -gt 0 ]]; do
    case "$1" in
        --profile)
            PROFILE="$2"
            shift 2
            ;;
        --plan)
            PLAN_PATH="$2"
            shift 2
            ;;
        *)
            error "Unknown option: $1"
            ;;
    esac
done

# -- Guard: no latest -----------------------------------------------------------
if [[ "$IMAGE_TAG" == "latest" ]]; then
    error "image_tag must NOT be 'latest'. Use a pinned version tag or digest."
fi

# -- Paths ---------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="$SCRIPT_DIR/../../deploy/aws/company-existing"
TFVARS="$TF_DIR/envs/${ENV_NAME}.tfvars"
WORKSPACE="$ENV_NAME"

# -- Guard: tfvars must exist --------------------------------------------------
if [[ ! -f "$TFVARS" ]]; then
    error "tfvars not found: $TFVARS"$'\n'"Copy 'envs/${ENV_NAME}.tfvars.example' to 'envs/${ENV_NAME}.tfvars' and fill real values."
fi

# -- Load account helpers ------------------------------------------------------
source "$SCRIPT_DIR/terraform-accounts.sh"

# -- Guard: account allowlist --------------------------------------------------
info "Validating AWS account for environment '$ENV_NAME'..."
if ! validate_account "$ENV_NAME" "$PROFILE"; then
    error "Account validation failed. Aborting apply to prevent cross-account operations."
fi

# -- Guard: workspace must exist (no auto-create) ------------------------------
info "Validating workspace '$WORKSPACE' exists..."
if ! validate_workspace "$TF_DIR" "$WORKSPACE" "$ENV_NAME"; then
    error "Workspace '$WORKSPACE' does not exist. Cannot auto-create. Contact Releaser/Human to approve workspace creation."
fi

# -- Avoid external TF_WORKSPACE pollution -------------------------------------
unset TF_WORKSPACE

# -- Guard: select workspace explicitly (prevents wrong-workspace apply) --------
info "Selecting workspace: $WORKSPACE"
if ! terraform -chdir="$TF_DIR" workspace select "$WORKSPACE"; then
    error "Failed to select workspace '$WORKSPACE'. Aborting apply."
fi

# -- Display context -----------------------------------------------------------
ACCOUNT_ID=$(get_actual_account "$PROFILE")
echo ""
echo "=== Terraform Apply Context ==="
echo "  Environment:     $ENV_NAME"
echo "  AWS Profile:     $PROFILE"
echo "  AWS Account:     $ACCOUNT_ID"
echo "  Workspace:       $WORKSPACE"
echo "  TF_DIR:          $TF_DIR"
echo "  TFVARS:          $TFVARS"
echo "  Image tag:       $IMAGE_TAG"
echo "==============================="
echo ""

# -- Find or validate plan artifact --------------------------------------------
if [[ -z "$PLAN_PATH" ]]; then
    # Find latest plan for this environment
    PLAN_PATH=$(ls -t "$TF_DIR"/plans/tfplan-${ENV_NAME}-*.tfplan 2>/dev/null | head -1)
    if [[ -z "$PLAN_PATH" ]]; then
        error "No plan artifact found for environment '$ENV_NAME'."$'\n'"Run terraform-plan.sh first to generate a plan artifact."$'\n'"Or specify --plan <path> to use a specific plan."
    fi

    # -- Warning: auto-found plan is not HITL-reviewed -------------------------
    warn ""
    warn "========================================"
    warn "  AUTO-FOUND PLAN -- NOT HITL REVIEWED"
    warn "========================================"
    warn ""
    warn "You did not specify --plan. The script found the latest plan artifact:"
    warn "  $PLAN_PATH"
    warn ""
    warn "This auto-find is a DEV CONVENIENCE only. For Phase 4 / HITL production"
    warn "apply, you MUST use --plan to specify a specific binary plan that has been"
    warn "reviewed and approved via Human HITL. Do not apply an auto-found plan in"
    warn "production without explicit HITL review of the plan contents."
    warn ""
    info "Using latest plan artifact: $PLAN_PATH"
else
    if [[ ! -f "$PLAN_PATH" ]]; then
        error "Plan artifact not found: $PLAN_PATH"
    fi

    # -- Guard: plan basename must belong to this environment ------------------
    PLAN_BASENAME=$(basename "$PLAN_PATH")
    if [[ ! "$PLAN_BASENAME" =~ ^tfplan-${ENV_NAME}-.*\.tfplan$ ]]; then
        error "Plan basename '$PLAN_BASENAME' does not match expected pattern ^tfplan-${ENV_NAME}-.*\\.tfplan$."$'\n'"       This prevents cross-environment plan confusion."$'\n'"       For environment '$ENV_NAME', the plan filename must start with 'tfplan-${ENV_NAME}-'."
    fi
    info "Using specified plan artifact: $PLAN_PATH"
fi

# -- Guard: plan artifact must exist -------------------------------------------
if [[ ! -f "$PLAN_PATH" ]]; then
    error "Plan artifact not found: $PLAN_PATH"
fi

# -- Review plan summary -------------------------------------------------------
info "Reviewing plan artifact: $PLAN_PATH"
echo ""
echo "=== Plan Summary ==="
terraform -chdir="$TF_DIR" show -no-color "$PLAN_PATH" | head -50
echo ""

PLAN_FILE_TIME=$(stat -c '%y' "$PLAN_PATH" 2>/dev/null | cut -d'.' -f1 || date -r "$PLAN_PATH" '+%Y-%m-%d %H:%M:%S')
info "Plan generated at: $PLAN_FILE_TIME"

# -- Check for destructive operations ------------------------------------------
PLAN_CONTENT=$(terraform -chdir="$TF_DIR" show -no-color "$PLAN_PATH" 2>&1)

if is_destructive_plan "$PLAN_CONTENT"; then
    local destructiveness
    destructiveness=$(describe_plan_destructiveness "$PLAN_CONTENT")
    warn ""
    warn "========================================"
    warn "  DESTRUCTIVE OPERATIONS DETECTED!"
    warn "  Status: $destructiveness"
    warn "========================================"
    warn ""
    echo "$PLAN_CONTENT" | grep -iE "(Plan:|must be replaced|-/+)" | head -20
    echo ""
    warn "This plan contains destroy/replace operations."
    warn "Automatic apply is BLOCKED."
    echo ""
    echo -e "${YELLOW}If you have reviewed this plan and want to proceed, you must:${NC}"
    echo "  1. Confirm this is the correct plan for environment '$ENV_NAME'"
    echo "  2. Acknowledge the destroy/replace operations above"
    echo "  3. Provide explicit approval for these operations"
    echo ""
    read -r -p "Type 'approve destroy' to acknowledge and proceed: " confirm
    echo ""

    if [[ "$confirm" != "approve destroy" ]]; then
        info "Apply cancelled. No changes made."
        exit 1
    fi

    warn "Destroy/replace operations acknowledged by user."
else
    success "Plan contains no destroy/replace operations."
fi

# -- Confirmation prompt -------------------------------------------------------
echo ""
echo -e "${YELLOW}════════════════════════════════════════════════════════════════${NC}"
echo -e "${YELLOW}  Terraform Apply Confirmation${NC}"
echo -e "${YELLOW}════════════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "  ${BOLD}Environment:${NC}   $ENV_NAME"
echo -e "  ${BOLD}Workspace:${NC}    $WORKSPACE"
echo -e "  ${BOLD}Image tag:${NC}    $IMAGE_TAG"
echo -e "  ${BOLD}AWS profile:${NC}  $PROFILE"
echo -e "  ${BOLD}Account ID:${NC}   $ACCOUNT_ID"
echo -e "  ${BOLD}TF_DIR:${NC}       $TF_DIR"
echo -e "  ${BOLD}TFVARS:${NC}       $TFVARS"
echo -e "  ${BOLD}Plan artifact:${NC} $PLAN_PATH"
echo ""
echo -e "${YELLOW}!  This will apply the plan and create/modify AWS resources in account ${ACCOUNT_ID}.${NC}"
echo ""
read -r -p "Type 'apply ${ENV_NAME}' to continue: " confirm
echo ""

if [[ "$confirm" != "apply ${ENV_NAME}" ]]; then
    info "Apply cancelled. No changes made."
    exit 1
fi

# -- Terraform apply (using binary plan artifact) -----------------------------
info "Applying Terraform plan from artifact: $PLAN_PATH"
AWS_PROFILE="$PROFILE" terraform -chdir="$TF_DIR" apply "$PLAN_PATH"

success "Apply complete for env=$ENV_NAME"
echo ""
echo "=== Apply Summary ==="
echo "  Environment:  $ENV_NAME"
echo "  Workspace:    $WORKSPACE"
echo "  Plan artifact: $PLAN_PATH"
echo "  Applied at:   $(date '+%Y-%m-%d %H:%M:%S')"
