#!/usr/bin/env bash
# =============================================================================
# populate_litellm_runtime_values.sh
#
# Idempotent script to populate LiteLLM ECS runtime values into AWS Secrets Manager.
#
# Usage:
#   ./populate_litellm_runtime_values.sh --config <path> [--dry-run] [--yes]
#
# Prerequisites:
#   - AWS CLI configured with appropriate credentials for the target account.
#   - Shell env vars LITELLM_MASTER_KEY and LITELLM_SALT_KEY set with the
#     desired plaintext values (script will NOT echo them).
#   - RDS instance must exist and be accessible with the configured AWS profile.
#   - Secret names in the config must match what the Terraform data module creates.
#
# Security reminders:
#   - This script does NOT echo or log any secret values.
#   - Use --dry-run to verify what would be written before making changes.
#   - Never commit real secret values to the repository.
# =============================================================================

set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────────────────────
DEFAULT_CONFIG="infra/aws/envs/route-b-light.env"
CONFIG=""
DRY_RUN=""
AUTO_YES=""

# ── Usage ─────────────────────────────────────────────────────────────────────
usage() {
  cat <<EOF
Usage: $(basename "$0") [--config <path>] [--dry-run] [--yes] [--help]

Populate LiteLLM ECS runtime values into AWS Secrets Manager for Route B-light.

Arguments:
  --config <path>   Path to env config file (default: ${DEFAULT_CONFIG})
  --dry-run         Show what would be written without making changes.
  --yes             Skip interactive confirmation prompt.
  --help            Show this help message.

Prerequisites:
  - LITELLM_MASTER_KEY and LITELLM_SALT_KEY must be set in the shell environment.
  - AWS CLI must be configured with credentials for the target account/region.
  - RDS instance must be accessible.

Example:
  export LITELLM_MASTER_KEY="your-master-key"
  export LITELLM_SALT_KEY="your-salt-key"
  ./populate_litellm_runtime_values.sh --config infra/aws/envs/route-b-light.env --dry-run
EOF
}

# ── Parse arguments ────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --config)
      CONFIG="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --yes)
      AUTO_YES=1
      shift
      ;;
    --help)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

# Default config if not provided
CONFIG="${CONFIG:-${DEFAULT_CONFIG}}"

# ── Config file existence check ────────────────────────────────────────────────
if [[ ! -f "$CONFIG" ]]; then
  echo "ERROR: Config file not found: ${CONFIG}" >&2
  echo "Hint: Copy 'infra/aws/envs/route-b-light.env.example' to the same location," >&2
  echo "      rename it to 'route-b-light.env', and fill in your values." >&2
  exit 1
fi

# ── Load config (only check it exists; do NOT echo its contents) ───────────────
# We source with care: prevent accidental exposure of secrets if user misconfigures.
# shellcheck source=/dev/null
source "$CONFIG"

# ── Validate required config variables ────────────────────────────────────────
REQUIRED_CONFIG_VARS=(
  AWS_PROFILE
  AWS_REGION
  RDS_IDENTIFIER
  RDS_USERNAME
  RDS_DB_NAME
  LITELLM_MASTER_SECRET_NAME
  DATABASE_URL_SECRET_NAME
  REDIS_PASSWORD_SECRET_NAME
  LITELLM_SALT_SECRET_NAME
)

missing_config=""
for var in "${REQUIRED_CONFIG_VARS[@]}"; do
  # Check if variable is unset or empty
  if [[ -z "${!var:-}" ]]; then
    missing_config="${missing_config}  - ${var} (from config)\n"
  fi
done

if [[ -n "${missing_config}" ]]; then
  echo "ERROR: Missing required config variables in ${CONFIG}:" >&2
  echo -e "${missing_config}" >&2
  exit 1
fi

# ── Validate required shell environment variables ───────────────────────────────
REQUIRED_ENV_VARS=(
  LITELLM_MASTER_KEY
  LITELLM_SALT_KEY
)

missing_env=""
for var in "${REQUIRED_ENV_VARS[@]}"; do
  if [[ -z "${!var:-}" ]]; then
    missing_env="${missing_env}  - ${var}\n"
  fi
done

if [[ -n "${missing_env}" ]]; then
  echo "ERROR: Missing required shell environment variables:" >&2
  echo -e "${missing_env}" >&2
  echo "Hint: Set them before running this script, e.g.:" >&2
  echo "  export LITELLM_MASTER_KEY=\"your-master-key\"" >&2
  echo "  export LITELLM_SALT_KEY=\"your-salt-key\"" >&2
  exit 1
fi

# ── Check AWS CLI availability ─────────────────────────────────────────────────
if ! command -v aws &>/dev/null; then
  echo "ERROR: AWS CLI (aws) is not installed or not in PATH." >&2
  exit 1
fi

# ── Header ─────────────────────────────────────────────────────────────────────
echo "=========================================="
echo "LiteLLM Runtime Values Population"
echo "=========================================="
echo "Config:       ${CONFIG}"
echo "AWS Profile:  ${AWS_PROFILE}"
echo "AWS Region:   ${AWS_REGION}"
echo "RDS ID:      ${RDS_IDENTIFIER}"
echo "Dry-run:     ${DRY_RUN:-false}"
echo ""

# ── Describe RDS instance ─────────────────────────────────────────────────────
echo "[1/5] Querying RDS instance: ${RDS_IDENTIFIER} ..."

RDS_JSON=$(aws rds describe-db-instances \
  --profile "${AWS_PROFILE}" \
  --region "${AWS_REGION}" \
  --db-instance-identifier "${RDS_IDENTIFIER}" \
  --output json 2>&1) || {
    echo "ERROR: Failed to describe RDS instance '${RDS_IDENTIFIER}'." >&2
    echo "${RDS_JSON}" >&2
    exit 1
  }

# Extract endpoint, port, and master secret ARN via Python (no jq dependency)
RDS_INFO=$(env _RDS_JSON="$RDS_JSON" python3 - <<'PYEOF'
import json, os, sys
data = json.loads(os.environ["_RDS_JSON"])
instances = data.get("DBInstances", [])
if not instances:
    sys.exit(1)
inst = instances[0]
endpoint = inst.get("Endpoint", {})
address = endpoint.get("Address", "")
port = endpoint.get("Port", 5432)
master_secret = inst.get("MasterUserSecret", {})
secret_arn = master_secret.get("SecretArn", "")
print(f"{address}|{port}|{secret_arn}")
PYEOF
) || {
    echo "ERROR: Failed to parse RDS describe-db-instances output." >&2
    echo "Is the RDS identifier correct and does the instance exist?" >&2
    exit 1
}

RDS_ENDPOINT="${RDS_INFO%%|*}"
rest="${RDS_INFO#*|}"
RDS_PORT="${rest%%|*}"
RDS_SECRET_ARN="${rest##*|}"

echo "  RDS Endpoint:  ${RDS_ENDPOINT}"
echo "  RDS Port:     ${RDS_PORT}"
echo "  RDS Secret ARN: ${RDS_SECRET_ARN}"

if [[ -z "${RDS_ENDPOINT}" || -z "${RDS_PORT}" || -z "${RDS_SECRET_ARN}" ]]; then
  echo "ERROR: Could not retrieve RDS endpoint, port, or secret ARN." >&2
  exit 1
fi

# ── Retrieve RDS managed master password ──────────────────────────────────────
echo ""
echo "[2/5] Retrieving RDS master password from Secrets Manager ..."

RDS_SECRET_JSON=$(aws secretsmanager get-secret-value \
  --profile "${AWS_PROFILE}" \
  --region "${AWS_REGION}" \
  --secret-id "${RDS_SECRET_ARN}" \
  --output json 2>&1) || {
    echo "ERROR: Failed to get RDS master password from Secrets Manager." >&2
    echo "${RDS_SECRET_JSON}" >&2
    exit 1
  }

# Parse the secret JSON using Python standard library
RDS_PASSWORD=$(env _RDS_SECRET_JSON="$RDS_SECRET_JSON" python3 - <<'PYEOF'
import json, os, sys
data = json.loads(os.environ["_RDS_SECRET_JSON"])
# SecretString contains {"password":"...", "username":"...", "dbname":"...", "engine":"...", "host":"...", "port":...}
secret_str = data.get("SecretString", "")
if not secret_str:
    sys.exit(1)
secret = json.loads(secret_str)
password = secret.get("password", "")
print(password)
PYEOF
) || {
    echo "ERROR: Failed to parse RDS secret JSON." >&2
    exit 1
}

if [[ -z "${RDS_PASSWORD}" ]]; then
  echo "ERROR: RDS password retrieved was empty." >&2
  exit 1
fi

# ── Construct DATABASE_URL ───────────────────────────────────────────────────
DATABASE_URL="postgresql://${RDS_USERNAME}:${RDS_PASSWORD}@${RDS_ENDPOINT}:${RDS_PORT}/${RDS_DB_NAME}"

# ── Confirm before writing (unless --yes or --dry-run) ────────────────────────
if [[ -z "${DRY_RUN}" ]]; then
  echo ""
  echo "[3/5] Summary of secrets to be written:"
  echo "  Secret name          Value source"
  echo "  -------------------  --------------------------------------------"
  echo "  ${LITELLM_MASTER_SECRET_NAME}    (from shell env LITELLM_MASTER_KEY)"
  echo "  ${LITELLM_SALT_SECRET_NAME}       (from shell env LITELLM_SALT_KEY)"
  echo "  ${DATABASE_URL_SECRET_NAME}    (constructed from RDS managed secret)"
  echo "  ${REDIS_PASSWORD_SECRET_NAME}   (from config REDIS_PASSWORD_VALUE)"
  echo ""
  echo "  Database URL host: ${RDS_ENDPOINT}"
  echo ""

  if [[ -z "${AUTO_YES}" ]]; then
    echo "WARNING: This will write secret values to AWS Secrets Manager." >&2
    read -rp "  Continue? (type 'yes' to confirm): " confirm <&2
    if [[ "${confirm}" != "yes" ]]; then
      echo "Aborted."
      exit 0
    fi
  fi
else
  echo "[3/5] Dry-run mode — summary of what would be written:"
  echo "  Secret name          Value source"
  echo "  -------------------  --------------------------------------------"
  echo "  ${LITELLM_MASTER_SECRET_NAME}    (from shell env LITELLM_MASTER_KEY)"
  echo "  ${LITELLM_SALT_SECRET_NAME}       (from shell env LITELLM_SALT_KEY)"
  echo "  ${DATABASE_URL_SECRET_NAME}    (constructed from RDS managed secret)"
  echo "  ${REDIS_PASSWORD_SECRET_NAME}   (from config REDIS_PASSWORD_VALUE)"
  echo ""
  echo "  Database URL host: ${RDS_ENDPOINT}"
fi

# ── Write secrets ──────────────────────────────────────────────────────────────
echo ""
if [[ -z "${DRY_RUN}" ]]; then
  echo "[4/5] Writing secrets to AWS Secrets Manager ..."
else
  echo "[4/5] Dry-run — skipping AWS write."
fi

# Helper function to write a secret (or skip in dry-run)
write_secret() {
  local secret_name="$1"
  local secret_value="$2"
  if [[ -n "${DRY_RUN}" ]]; then
    echo "  [SKIP dry-run] aws secretsmanager put-secret-value --secret-id '${secret_name}'"
    return 0
  fi
  aws secretsmanager put-secret-value \
    --profile "${AWS_PROFILE}" \
    --region "${AWS_REGION}" \
    --secret-id "${secret_name}" \
    --secret-string "${secret_value}" \
    >/dev/null 2>&1 || {
      echo "  ERROR: Failed to write secret: ${secret_name}" >&2
      return 1
    }
  echo "  OK: ${secret_name}"
}

# Write LITELLM_MASTER_KEY secret
write_secret "${LITELLM_MASTER_SECRET_NAME}" "${LITELLM_MASTER_KEY}"

# Write LITELLM_SALT_KEY secret
write_secret "${LITELLM_SALT_SECRET_NAME}" "${LITELLM_SALT_KEY}"

# Write DATABASE_URL secret
write_secret "${DATABASE_URL_SECRET_NAME}" "${DATABASE_URL}"

# Write REDIS_PASSWORD secret (may be empty string)
write_secret "${REDIS_PASSWORD_SECRET_NAME}" "${REDIS_PASSWORD_VALUE:-}"

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
echo "[5/5] Complete."
echo ""
if [[ -n "${DRY_RUN}" ]]; then
  echo "Dry-run completed. No secrets were written."
  echo "Re-run without --dry-run to apply changes."
else
  echo "All secrets written successfully:"
  echo "  - ${LITELLM_MASTER_SECRET_NAME}"
  echo "  - ${LITELLM_SALT_SECRET_NAME}"
  echo "  - ${DATABASE_URL_SECRET_NAME}"
  echo "  - ${REDIS_PASSWORD_SECRET_NAME}"
fi
