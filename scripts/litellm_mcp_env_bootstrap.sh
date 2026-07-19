#!/bin/bash
# =============================================================================
# LiteLLM MCP Env Bootstrap Helper
# =============================================================================
# Purpose: Safe local init/check for MCP credential env vars in root .env.
#          Does NOT read .opencode/.env or .opencode/secrets/*.
# Modes:
#   --check              : Read-only status report (missing / empty / present).
#   --init-local         : Append missing MCP key stubs to root .env.
#   --validate-container : Compare root .env presence to litellm-proxy container env.
#   --health             : Call LiteLLM MCP health endpoint; summarize statuses.
#   --recreate-local     : Ask confirmation, then docker compose recreate (requires --yes).
# =============================================================================

set -uo pipefail

# ── Constants ────────────────────────────────────────────────────────────────

SCRIPT_NAME="$(basename "$0")"
ENV_FILE="${ENV_FILE:-.env}"
CONFIG_FILE="${CONFIG_FILE:-config.yaml}"

# Required MCP env var names (ordered for stable output)
MCP_VAR_NAMES=(
  "TAVILY_API_KEY"
  "SUPERMEMORY_API_KEY"
  "BRAVE_API_KEY"
  "GITHUB_PERSONAL_ACCESS_TOKEN"
)

# LiteLLM MCP server names (matching config.yaml keys)
# ── Phase E: codebase_memory_mcp added (no API key required) ──────────────────
# ── Phase F1: sequentialthinking_mcp added (no API key required) ───────────────
# ── Phase F2a: playwright_mcp added (HTTP sidecar, no API key required) ────────
# ── Track C: mermaid_mcp added (HTTP sidecar, no API key required) ─────────────
MCP_SERVER_NAMES=(
  "tavily_mcp"
  "supermemory_mcp"
  "brave_search_mcp"
  "playwright_mcp"
  "mermaid_mcp"
  "codebase_memory_mcp"
  "sequentialthinking_mcp"
  "github_mcp"
)

# ── Helpers ──────────────────────────────────────────────────────────────────

# Print to stderr
warn()  { echo "$SCRIPT_NAME: warn: $*" >&2; }
error() { echo "$SCRIPT_NAME: error: $*" >&2; }
info()  { echo "$SCRIPT_NAME: info: $*" >&2; }

# Guarded parser for LITELLM_MASTER_KEY — never prints the value.
# Returns 0 + echoes "present(length=N)" or "empty" or "missing".
_parse_master_key() {
  local env_file="$1"
  if [[ ! -f "$env_file" ]]; then
    echo "missing"
    return 1
  fi

  local val
  val=$(grep -m1 "^LITELLM_MASTER_KEY=" "$env_file" 2>/dev/null | cut -d'=' -f2- | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

  if [[ -z "$val" ]]; then
    echo "empty"
    return 1
  fi

  local len=${#val}
  # Sanity: master key must be at least 8 chars to be plausible
  if [[ "$len" -lt 8 ]]; then
    echo "empty"
    return 1
  fi

  echo "present(length=${len})"
  return 0
}

# Check if a server block in config.yaml has an active (non-commented) url: line.
# Args: config_file server_name
# Returns 0 + echo "enabled" / "disabled" / "not_found"
_config_server_enabled() {
  local cfg="$1"
  local server="$2"

  if [[ ! -f "$cfg" ]]; then
    echo "not_found"
    return 1
  fi

  # Extract the block for this server using awk paragraph mode.
  # A block is enabled when it contains a url: line that is NOT commented out.
  local result
  result=$(awk -v server="$server" '
    BEGIN { in_block=0; has_active_url=0; has_disabled_url=0 }
    /^[[:space:]]*#/ { next }
    $0 ~ "^[[:space:]]*" server "[[:space:]]*:" { in_block=1; next }
    in_block && /^[[:space:]]*url:[[:space:]]*/ {
      has_active_url=1; next
    }
    in_block && /^[[:space:]]*_disabled_reason:/ {
      has_disabled_url=1; next
    }
    in_block && /^[[:space:]]*[a-zA-Z_][a-zA-Z0-9_]*:[[:space:]]*/ {
      # A new top-level key ends the block (unless same server name)
      if ($0 !~ "^[[:space:]]*" server ":") {
        in_block = 0
      }
    }
    END {
      if (has_active_url) {
        print "enabled"
      } else if (has_disabled_url) {
        print "disabled"
      } else {
        print "not_found"
      }
    }
  ' "$cfg" 2>/dev/null)

  echo "${result:-not_found}"
  [[ "$result" == "enabled" ]]
}

# Read a single env var status from file, return "missing" / "empty" / "present".
# Never echoes the value.
_env_var_status() {
  local env_file="$1"
  local var_name="$2"

  if [[ ! -f "$env_file" ]]; then
    echo "missing"
    return
  fi

  local val
  val=$(grep -m1 "^${var_name}=" "$env_file" 2>/dev/null | cut -d'=' -f2- | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

  if grep -q "^${var_name}=" "$env_file" 2>/dev/null; then
    if [[ -z "$val" ]]; then
      echo "empty"
    else
      echo "present"
    fi
  else
    echo "missing"
  fi
}

# Append a missing MCP key stub to .env (only if key does not exist at all).
_append_missing_stub() {
  local env_file="$1"
  local var_name="$2"

  # Skip if already present (even if empty — do not overwrite)
  if grep -q "^${var_name}=" "$env_file" 2>/dev/null; then
    return 1
  fi

  printf '\n# MCP Server API Key — fill value before use; never commit secrets\n' >> "$env_file"
  printf '%s=\n' "$var_name" >> "$env_file"
  return 0
}

# ── Mode: --check ────────────────────────────────────────────────────────────

do_check() {
  local env_file="${1:-$ENV_FILE}"

  echo "=== LiteLLM MCP Env Status Check ==="
  echo "Env file: $env_file"
  echo ""

  if [[ ! -f "$env_file" ]]; then
    warn "Env file '$env_file' does not exist."
    echo ""
    for var in "${MCP_VAR_NAMES[@]}"; do
      echo "  $var : missing"
    done
    echo ""
    info "Run '$SCRIPT_NAME --init-local' to scaffold missing keys."
    return 1
  fi

  local any_missing=0
  local any_empty=0

  for var in "${MCP_VAR_NAMES[@]}"; do
    local status
    status=$(_env_var_status "$env_file" "$var")
    echo "  $var : $status"
    [[ "$status" == "missing" ]] && ((any_missing++))
    [[ "$status" == "empty"   ]] && ((any_empty++))
  done

  echo ""

  if [[ "$any_missing" -gt 0 ]]; then
    warn "$any_missing key(s) are entirely absent from env file."
    info "Run '$SCRIPT_NAME --init-local' to append stub entries."
  fi

  if [[ "$any_empty" -gt 0 ]]; then
    warn "$any_empty key(s) have empty values — container will receive empty strings."
    info "Fill in real values in '$env_file', then recreate the container."
  fi

  if [[ "$any_missing" -eq 0 && "$any_empty" -eq 0 ]]; then
    info "All required MCP keys are present and non-empty."
  fi

  # Also check if config.yaml MCP servers are enabled
  if [[ -f "$CONFIG_FILE" ]]; then
    echo ""
    echo "=== config.yaml MCP Server Status ==="
    for server in "${MCP_SERVER_NAMES[@]}"; do
      local srv_status
      srv_status=$(_config_server_enabled "$CONFIG_FILE" "$server")
      if [[ "$srv_status" == "enabled" ]]; then
        echo "  $server : enabled"
      elif [[ "$srv_status" == "disabled" ]]; then
        echo "  $server : disabled (advisory)"
      else
        echo "  $server : not_found"
      fi
    done
  fi

  return 0
}

# ── Mode: --init-local ───────────────────────────────────────────────────────

do_init_local() {
  local env_file="${1:-$ENV_FILE}"

  echo "=== LiteLLM MCP Env Init (Local) ==="
  echo "Target: $env_file"
  echo ""

  if [[ ! -f "$env_file" ]]; then
    error "Env file '$env_file' does not exist. Run deploy.sh or create it first."
    return 1
  fi

  # Confirm permissions
  local perms
  perms=$(stat -c "%a" "$env_file" 2>/dev/null || echo "unknown")
  if [[ "$perms" != "600" ]]; then
    warn "Env file permissions are $perms (expected 600). Fixing..."
    chmod 600 "$env_file" || { error "chmod 600 failed"; return 1; }
    info "Permissions updated to 600."
  fi

  local appended=0
  for var in "${MCP_VAR_NAMES[@]}"; do
    if _append_missing_stub "$env_file" "$var"; then
      echo "  + appended stub: $var="
      ((appended++))
    else
      echo "  ~ preserved existing: $var"
    fi
  done

  echo ""
  if [[ "$appended" -gt 0 ]]; then
    info "Appended $appended stub(s). Fill in real values in '$env_file'."
    info "After editing, run: docker compose up -d --force-recreate litellm"
  else
    info "No new stubs needed — all required keys already present."
  fi

  return 0
}

# ── Mode: --validate-container ──────────────────────────────────────────────

do_validate_container() {
  echo "=== Container Env Validation ==="
  echo ""

  # Check Docker availability
  if ! command -v docker &>/dev/null; then
    info "Docker not available — skipping container check."
    return 0
  fi

  if ! docker info &>/dev/null; then
    info "Docker daemon not reachable — skipping container check."
    return 0
  fi

  # Check container exists
  if ! docker inspect litellm-proxy &>/dev/null; then
    info "Container 'litellm-proxy' is not running — skipping container check."
    info "Start services with: docker compose up -d"
    return 0
  fi

  local env_file="${1:-$ENV_FILE}"
  echo "Comparing root .env vs container environment..."
  echo ""

  local any_mismatch=0
  local container_status=0

  for var in "${MCP_VAR_NAMES[@]}"; do
    local file_status
    file_status=$(_env_var_status "$env_file" "$var")

    local container_val
    container_val=$(docker inspect litellm-proxy --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null | \
      grep "^${var}=" | head -1 | cut -d'=' -f2-)

    local container_status_str
    if [[ -z "$container_val" ]]; then
      container_status_str="empty"
    else
      container_status_str="present(length=${#container_val})"
    fi

    local match="ok"
    if [[ "$file_status" == "present" && "$container_status_str" == "empty" ]]; then
      match="MISMATCH — .env has value, container env is empty"
      ((any_mismatch++))
    elif [[ "$file_status" == "empty" && "$container_status_str" != "empty" ]]; then
      match="MISMATCH — .env empty, container has value"
      ((any_mismatch++))
    fi

    printf '  %-35s .env=%-10s  container=%s\n' "$var" "$file_status" "$container_status_str"
    if [[ "$match" != "ok" ]]; then
      echo "    ^ $match"
    fi
  done

  echo ""
  if [[ "$any_mismatch" -gt 0 ]]; then
    warn "$any_mismatch mismatch(es) found — container may need recreate."
    info "Run: docker compose up -d --force-recreate litellm"
  else
    info "Container env matches .env presence status."
  fi

  return 0
}

# ── Mode: --health ───────────────────────────────────────────────────────────

do_health() {
  echo "=== LiteLLM MCP Health Check ==="
  echo ""

  local env_file="${1:-$ENV_FILE}"

  # Read LITELLM_MASTER_KEY status (never print value)
  local key_status
  key_status=$(LITELLM_MASTER_KEY= \
    _parse_master_key "$env_file")

  echo "LITELLM_MASTER_KEY : $key_status"

  if [[ "$key_status" == "missing" ]]; then
    error "LITELLM_MASTER_KEY is missing from '$env_file'."
    info "Cannot call health endpoint without a valid master key."
    return 1
  fi

  if [[ "$key_status" == "empty" ]]; then
    error "LITELLM_MASTER_KEY is empty in '$env_file'."
    info "Cannot call health endpoint with an empty key."
    return 1
  fi

  # Extract key value in a subshell for the curl call — never echoed to logs
  local api_key
  api_key=$(grep -m1 "^LITELLM_MASTER_KEY=" "$env_file" 2>/dev/null | cut -d'=' -f2- | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

  # Detect LiteLLM endpoint
  local endpoint="http://localhost:4000"
  if command -v docker &>/dev/null && docker inspect litellm-proxy &>/dev/null; then
    local container_status
    container_status=$(docker inspect litellm-proxy --format '{{.State.Status}}' 2>/dev/null)
    if [[ "$container_status" != "running" ]]; then
      warn "Container is not running (status: $container_status). Health check may fail."
    fi
  else
    info "Container not detected; checking localhost:4000 directly."
  fi

  echo ""
  echo "Calling MCP health endpoint..."
  echo ""

  local response
  local curl_output
  local http_code

  # Suppress curl progress; capture response and HTTP code
  curl_output=$(curl -s \
    --max-time 10 \
    -w "\n%{http_code}" \
    -H "Authorization: Bearer ${api_key}" \
    "${endpoint}/v1/mcp/server/health" 2>/dev/null || echo "__CURL_FAILED__")

  if [[ "$curl_output" == "__CURL_FAILED__" ]]; then
    warn "Could not reach ${endpoint}/v1/mcp/server/health"
    info "Ensure LiteLLM is running and reachable."
    return 1
  fi

  http_code="${curl_output##*$'\n'}"
  response="${curl_output%$'\n'*}"

  echo "HTTP ${http_code}"
  echo ""

  # Parse and display health statuses without secrets
  if command -v python3 &>/dev/null; then
    RESPONSE_JSON="$response" python3 - <<'PYEOF' 2>/dev/null
import sys, json
try:
    import os
    data = json.loads(os.environ.get("RESPONSE_JSON", ""))
    if isinstance(data, list):
        for item in data:
            if isinstance(item, dict):
                server = item.get("server_name") or item.get("name") or item.get("server_id") or "unknown"
                status = item.get("status", "unknown")
                print(f"  {server}: {status}")
    elif isinstance(data, dict):
        servers = data.get("mcp_servers", data.get("servers", {}))
        if isinstance(servers, dict):
            for name, info in servers.items():
                status = info.get("status", "unknown") if isinstance(info, dict) else "unknown"
                print(f"  {name}: {status}")
        else:
            print("  (response format unexpected)")
    else:
        print("  (response format unexpected)")
except Exception:
    print("  Could not parse JSON response.")
PYEOF
  else
    # Fallback: just show truncated non-secret part
    echo "  (python3 not available — raw response below)"
    echo "$response" | head -20
  fi

  echo ""
  info "Health check complete."
  return 0
}

# ── Mode: --recreate-local ───────────────────────────────────────────────────

do_recreate_local() {
  local auto_yes="${1:-}"

  echo "=== LiteLLM Container Recreate ==="
  echo ""

  if ! command -v docker &>/dev/null; then
    error "Docker not available."
    return 1
  fi

  if ! docker info &>/dev/null; then
    error "Docker daemon not reachable."
    return 1
  fi

  if [[ "$auto_yes" != "--yes" ]]; then
    echo "This will force-recreate the 'litellm-proxy' container."
    echo "Container will restart with the current .env values."
    echo ""
    read -r -p "Continue? [y/N]: " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
      info "Cancelled."
      return 0
    fi
  else
    info "Auto-confirmed via --yes flag."
  fi

  echo ""
  info "Running: docker compose up -d --force-recreate litellm"
  echo ""

  if docker compose up -d --force-recreate litellm 2>&1; then
    info "Recreate initiated. Container may take ~60s to become healthy."
    info "Check status: docker compose ps"
  else
    error "Recreate command failed."
    return 1
  fi

  return 0
}

# ── Main dispatcher ───────────────────────────────────────────────────────────

usage() {
  cat <<EOF
$SCRIPT_NAME — LiteLLM MCP Env Bootstrap Helper

USAGE
  $SCRIPT_NAME <mode> [options]

MODES
  --check              Read-only status of MCP env vars in .env (no values shown).
  --init-local         Append missing MCP key stubs to root .env; preserve existing.
  --validate-container Compare root .env to litellm-proxy container environment.
  --health             Call LiteLLM MCP /v1/mcp/server/health and summarize statuses.
  --recreate-local     Ask confirmation then recreate litellm container. Requires --yes to auto-confirm.

OPTIONS
  --env-file <path>    Override .env file path (default: .env in current directory).
  --config-file <path> Override config.yaml path (default: config.yaml).
  --yes                Auto-confirm recreate prompt (use with --recreate-local only).

EXAMPLES
  # Check current status
  $SCRIPT_NAME --check

  # Scaffold missing keys
  $SCRIPT_NAME --init-local

  # After editing .env, recreate container
  $SCRIPT_NAME --recreate-local --yes

  # Check container env matches .env
  $SCRIPT_NAME --validate-container

  # Health check (requires running container)
  $SCRIPT_NAME --health

NOTES
  - Never reads .opencode/.env or .opencode/secrets/*.
  - Never prints secret values; only status (missing/empty/present).
  - LITELLM_MASTER_KEY is used for --health only and is never echoed.
EOF
}

main() {
  if [[ $# -eq 0 ]]; then
    usage
    exit 1
  fi

  local mode=""
  local env_file_arg=""
  local auto_yes=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --check)
        mode="check"
        shift
        ;;
      --init-local)
        mode="init-local"
        shift
        ;;
      --validate-container|--validate)
        mode="validate-container"
        shift
        ;;
      --health)
        mode="health"
        shift
        ;;
      --recreate-local)
        mode="recreate-local"
        shift
        ;;
      --env-file)
        env_file_arg="$2"
        shift 2
        ;;
      --config-file)
        CONFIG_FILE="$2"
        shift 2
        ;;
      --yes)
        auto_yes="--yes"
        shift
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      *)
        error "Unknown argument: $1"
        usage
        exit 1
        ;;
    esac
  done

  if [[ -z "$mode" ]]; then
    error "No mode specified."
    usage
    exit 1
  fi

  # Set env file from arg or default
  local env_file="${env_file_arg:-$ENV_FILE}"

  case "$mode" in
    check)              do_check "$env_file" ;;
    init-local)          do_init_local "$env_file" ;;
    validate-container)  do_validate_container "$env_file" ;;
    health)              do_health "$env_file" ;;
    recreate-local)      do_recreate_local "$auto_yes" ;;
    *)                   error "Unhandled mode: $mode" ; exit 1 ;;
  esac
}

main "$@"
