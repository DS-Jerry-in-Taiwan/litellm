#!/bin/bash
# =============================================================================
# LiteLLM AWS SSH Tunnel Helper
# =============================================================================
# Open an SSH tunnel from localhost to an internal ALB via a bastion host.
# Reads the ALB DNS name from Terraform outputs; never creates/modifies AWS
# resources or exposes secrets.
#
# Usage:
#   ./scripts/aws/open-tunnel.sh <env> --bastion <user@host>
#                                [--profile <aws_profile>]
#                                [--key <key.pem>]
#                                [--local-port <port>]
#                                [--remote-port <port>]
#
# Arguments:
#   env           Environment name (Terraform workspace / tfvars path)
#   --bastion     Required: SSH jump host (user@hostname or user@IP)
#   --profile     Optional AWS profile override (default: env name)
#   --key         Optional: path to SSH private key (passed to ssh -i)
#   --local-port  Optional: local port to listen on (default: 4000)
#   --remote-port Optional: remote port on ALB (default: 80)
#
# Examples:
#   ./scripts/aws/open-tunnel.sh office-mfa --bastion ubuntu@jump.example.com
#   ./scripts/aws/open-tunnel.sh office-mfa --bastion ubuntu@10.0.1.50 \
#       --key ~/.ssh/office-bastion.pem --local-port 4000
#   ./scripts/aws/open-tunnel.sh dev --bastion ec2-user@dev-bastion.internal
# =============================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'
error()   { echo -e "${RED}✗${NC} $1" >&2; exit 1; }
info()    { echo -e "${BLUE}ℹ${NC} $1"; }
success() { echo -e "${GREEN}✓${NC} $1"; }
warn()    { echo -e "${YELLOW}⚠${NC} $1"; }

show_usage() {
    cat <<EOF
Usage: $0 <env> --bastion <user@host>
              [--profile <aws_profile>]
              [--key <key.pem>]
              [--local-port <port>]
              [--remote-port <port>]

Arguments:
  env           Environment name (Terraform workspace / tfvars path)
  --bastion     Required: SSH jump host (user@hostname or user@IP)
  --profile     Optional AWS profile override (default: env name)
  --key         Optional: path to SSH private key (passed to ssh -i)
  --local-port  Optional: local port to listen on (default: 4000)
  --remote-port Optional: remote port on ALB (default: 80)

Examples:
  $0 office-mfa --bastion ubuntu@jump.example.com
  $0 office-mfa --bastion ubuntu@10.0.1.50 \\
      --key ~/.ssh/office-bastion.pem --local-port 4000
  $0 dev --bastion ec2-user@dev-bastion.internal
EOF
}

# ── Argument parsing ──────────────────────────────────────────────────────────
if [[ $# -lt 1 ]] || [[ "$1" == "--help" ]] || [[ "$1" == "-h" ]]; then
    show_usage
    exit 0
fi

ENV_NAME="$1"
shift

if [[ $# -lt 1 ]]; then
    error "Missing required --bastion argument. Run '$0 --help' for usage."
fi

BASTION=""
PROFILE="$ENV_NAME"  # default: AWS_PROFILE mirrors env name
KEY_FILE=""
LOCAL_PORT="4000"
REMOTE_PORT="80"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --bastion)
            if [[ $# -lt 2 ]]; then
                error "--bastion requires a value (e.g., --bastion ubuntu@jump.example.com)"
            fi
            BASTION="$2"
            shift 2
            ;;
        --profile)
            if [[ $# -lt 2 ]]; then
                error "--profile requires a value (e.g., --profile my-aws-profile)"
            fi
            PROFILE="$2"
            shift 2
            ;;
        --key)
            if [[ $# -lt 2 ]]; then
                error "--key requires a value (e.g., --key ~/.ssh/key.pem)"
            fi
            KEY_FILE="$2"
            shift 2
            ;;
        --local-port)
            if [[ $# -lt 2 ]]; then
                error "--local-port requires a value (e.g., --local-port 4000)"
            fi
            LOCAL_PORT="$2"
            shift 2
            ;;
        --remote-port)
            if [[ $# -lt 2 ]]; then
                error "--remote-port requires a value (e.g., --remote-port 80)"
            fi
            REMOTE_PORT="$2"
            shift 2
            ;;
        *)
            error "Unknown option: $1. Run '$0 --help' for usage."
            ;;
    esac
done

# ── Validate required --bastion ───────────────────────────────────────────────
if [[ -z "$BASTION" ]]; then
    error "Missing required --bastion argument. Run '$0 --help' for usage."
fi

# ── Validate port numbers ─────────────────────────────────────────────────────
if ! [[ "$LOCAL_PORT" =~ ^[0-9]+$ ]] || [[ "$LOCAL_PORT" -lt 1 ]] || [[ "$LOCAL_PORT" -gt 65535 ]]; then
    error "Invalid --local-port: $LOCAL_PORT (must be 1-65535)"
fi
if ! [[ "$REMOTE_PORT" =~ ^[0-9]+$ ]] || [[ "$REMOTE_PORT" -lt 1 ]] || [[ "$REMOTE_PORT" -gt 65535 ]]; then
    error "Invalid --remote-port: $REMOTE_PORT (must be 1-65535)"
fi

# ── Paths ────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="$SCRIPT_DIR/../../deploy/aws/company-existing"
WORKSPACE="$ENV_NAME"

# ── Avoid external TF_WORKSPACE pollution ─────────────────────────────────────
unset TF_WORKSPACE

# ── Set AWS profile for Terraform commands ────────────────────────────────────
if [[ -n "$PROFILE" ]]; then
    export AWS_PROFILE="$PROFILE"
fi

# ── Terraform init (backend may not be configured; use -backend=false) ─────────
info "Initializing Terraform (TF_DIR=$TF_DIR)..."
terraform -chdir="$TF_DIR" init -backend=false > /dev/null 2>&1 \
    || terraform -chdir="$TF_DIR" init > /dev/null 2>&1

# ── Workspace must already exist — never auto-create ─────────────────────────
info "Selecting workspace: $WORKSPACE"
if ! terraform -chdir="$TF_DIR" workspace select "$WORKSPACE" 2>/dev/null; then
    error "Workspace '$WORKSPACE' does not exist. " \
          "Run 'terraform-plan.sh $WORKSPACE <image_tag>' first to create it."
fi

# ── Read ALB DNS from Terraform output ────────────────────────────────────────
info "Fetching ALB DNS name from Terraform output..."
ALB_DNS=$(terraform -chdir="$TF_DIR" output -raw alb_dns_name 2>/dev/null) \
    || error "Failed to read 'alb_dns_name' from Terraform output. " \
             "Ensure the workspace is applied and 'alb_dns_name' output exists."

if [[ -z "$ALB_DNS" ]]; then
    error "Terraform output 'alb_dns_name' is empty. " \
          "Verify the workspace '$WORKSPACE' has been applied."
fi

# ── Build SSH command ─────────────────────────────────────────────────────────
SSH_CMD=("ssh" "-N" "-L" "${LOCAL_PORT}:${ALB_DNS}:${REMOTE_PORT}")
if [[ -n "$KEY_FILE" ]]; then
    if [[ ! -f "$KEY_FILE" ]]; then
        error "SSH key file not found: $KEY_FILE"
    fi
    SSH_CMD+=("-i" "$KEY_FILE")
fi
SSH_CMD+=("$BASTION")

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}════════════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  SSH Tunnel Ready${NC}"
echo -e "${GREEN}════════════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "  ${BOLD}Environment:${NC}   $ENV_NAME"
echo -e "  ${BOLD}Workspace:${NC}    $WORKSPACE"
echo -e "  ${BOLD}AWS profile:${NC}  $PROFILE"
echo -e "  ${BOLD}ALB DNS:${NC}      $ALB_DNS"
echo -e "  ${BOLD}Bastion:${NC}      $BASTION"
echo -e "  ${BOLD}Local port:${NC}   $LOCAL_PORT"
echo -e "  ${BOLD}Remote port:${NC} $REMOTE_PORT"
if [[ -n "$KEY_FILE" ]]; then
    echo -e "  ${BOLD}SSH key:${NC}     $KEY_FILE"
fi
echo ""
echo -e "${GREEN}  → Open in browser:${NC} ${BOLD}http://localhost:${LOCAL_PORT}/ui${NC}"
echo ""
echo -e "Press ${YELLOW}Ctrl+C${NC} to close the tunnel."
echo ""
warn "Keep this terminal open while using the browser."

# ── Open SSH tunnel (blocking) ──────────────────────────────────────────────────
info "Opening SSH tunnel..."
"${SSH_CMD[@]}"
