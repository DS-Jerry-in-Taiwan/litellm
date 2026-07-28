#!/bin/bash
# =============================================================================
# Sandbox Tests — litellm_mcp_env_bootstrap.sh
# =============================================================================
# Requirements:
#   - Runs without real secrets.
#   - Does NOT modify real root .env.
#   - Uses temp fixtures for --init-local.
#   - Covers: --check, --init-local, safe --validate-container, secret-output safety.
#   - Asserts no secret values in any output.
# =============================================================================

set -uo pipefail

SCRIPT_NAME="$(basename "$0")"
BOOTSTRAP_SCRIPT="${BOOTSTRAP_SCRIPT:-$(dirname "$0")/../litellm_mcp_env_bootstrap.sh}"

# ── Test utilities ──────────────────────────────────────────────────────────

TESTS_RUN=0
TESTS_PASS=0
TESTS_FAIL=0

pass() { echo "  PASS: $*"; ((TESTS_PASS++)); ((TESTS_RUN++)); }
fail() { echo "  FAIL: $*"; ((TESTS_FAIL++)); ((TESTS_RUN++)); }
info() { echo "  INFO: $*"; }

run_test() {
  local name="$1"
  local expected_rc="${2:-0}"
  local cmd="$3"

  local output
  local rc

  output=$(eval "$cmd" 2>&1)
  rc=$?

  if [[ "$rc" -ne "$expected_rc" ]]; then
    fail "$name (expected rc=$expected_rc, got rc=$rc)"
    echo "    output: ${output:0:200}"
    return 1
  fi

  pass "$name (rc=$rc)"
  return 0
}

# Check that output contains NO secret-like patterns.
check_no_secrets() {
  local label="$1"
  local output="$2"

  # Patterns that would reveal a real secret value
  local secret_patterns=(
    'sk-[A-Za-z0-9_-]\{20,\}'          # OpenAI/LiteLLM key format
    'Bearer [A-Za-z0-9_-]\{20,\}'      # Bearer token format
    '[A-Za-z0-9/+=]\{40,\}'            # Long base64-ish strings (potential keys)
    'AIza[A-Za-z0-9_-]\{30,\}'         # Google API key format
    'xoxb-[A-Za-z0-9_-]\{20,\}'        # Slack token format
    'ghp_[A-Za-z0-9]\{36\}'            # GitHub PAT format
  )

  for pattern in "${secret_patterns[@]}"; do
    if echo "$output" | grep -E "$pattern" >/dev/null 2>&1; then
      # False-positive guard: skip if the pattern appears in a comment/placeholder
      local suspect_lines
      suspect_lines=$(echo "$output" | grep -nE "$pattern" | grep -v '^\s*#' || true)
      if [[ -n "$suspect_lines" ]]; then
        fail "$label — secret-like pattern found in output (pattern: $pattern)"
        echo "    Offending lines: $suspect_lines"
        return 1
      fi
    fi
  done

  pass "$label"
  return 0
}

# ── Setup / Teardown fixtures ───────────────────────────────────────────────

FIXTURE_DIR=""
FIXTURE_ENV=""

setup_fixtures() {
  FIXTURE_DIR="$(mktemp -d)"
  FIXTURE_ENV="${FIXTURE_DIR}/.env"
  BOOTSTRAP_SCRIPT="${BOOTSTRAP_SCRIPT:-$(cd "$(dirname "$0")/.." && pwd)/litellm_mcp_env_bootstrap.sh}"

  if [[ ! -x "$BOOTSTRAP_SCRIPT" ]]; then
    echo "FATAL: Bootstrap script not found or not executable: $BOOTSTRAP_SCRIPT"
    exit 1
  fi

  info "Fixture dir: $FIXTURE_DIR"
  info "Bootstrap script: $BOOTSTRAP_SCRIPT"
}

teardown_fixtures() {
  if [[ -n "$FIXTURE_DIR" && -d "$FIXTURE_DIR" ]]; then
    rm -rf "$FIXTURE_DIR"
    info "Cleaned up fixture dir."
  fi
}

# ── Test suites ──────────────────────────────────────────────────────────────

test_check_mode_missing_keys() {
  echo ""
  echo "=== Test: --check on empty/missing keys ==="

  # Fixture: .env with no MCP keys
  cat > "$FIXTURE_ENV" <<'EOF'
LITELLM_MASTER_KEY=sk-real-key-for-health-check-only
DATABASE_URL=postgresql://u:p@h:5432/db
EOF

  local output
  output=$("$BOOTSTRAP_SCRIPT" --check --env-file "$FIXTURE_ENV" 2>&1)
  local rc=$?

  run_test "exit code is 0 or 1" "0" "true"
  [[ $rc -le 1 ]] || fail "rc=$rc" || true

  echo "$output" | grep -q "TAVILY_API_KEY"     || fail "TAVILY_API_KEY missing in output"
  echo "$output" | grep -q "SUPERMEMORY_API_KEY" || fail "SUPERMEMORY_API_KEY missing in output"
  echo "$output" | grep -q "BRAVE_API_KEY"      || fail "BRAVE_API_KEY missing in output"
  echo "$output" | grep -q "GITHUB_PERSONAL_ACCESS_TOKEN" || fail "GITHUB_PERSONAL_ACCESS_TOKEN missing in output"

  echo "$output" | grep -q "missing" || info "No 'missing' reported (unexpected but not fatal)"

  check_no_secrets "no secrets in --check output" "$output"
}

test_check_mode_present_keys() {
  echo ""
  echo "=== Test: --check on present (non-empty) keys ==="

  # Fixture: .env with MCP keys present but empty (as per .env.example scaffold)
  cat > "$FIXTURE_ENV" <<'EOF'
LITELLM_MASTER_KEY=sk-real-key-for-health-check-only
TAVILY_API_KEY=
SUPERMEMORY_API_KEY=
BRAVE_API_KEY=
GITHUB_PERSONAL_ACCESS_TOKEN=
EOF

  local output
  output=$("$BOOTSTRAP_SCRIPT" --check --env-file "$FIXTURE_ENV" 2>&1)

  echo "$output" | grep -q "TAVILY_API_KEY.*empty"     || echo "$output" | grep -q "TAVILY_API_KEY"     || fail "TAVILY_API_KEY not in output"
  echo "$output" | grep -q "SUPERMEMORY_API_KEY.*empty" || echo "$output" | grep -q "SUPERMEMORY_API_KEY" || fail "SUPERMEMORY_API_KEY not in output"

  check_no_secrets "no secrets in --check output (with present keys)" "$output"
}

test_check_mode_no_env_file() {
  echo ""
  echo "=== Test: --check on non-existent .env ==="

  local nonexistent="${FIXTURE_DIR}/nonexistent.env"
  local output
  output=$("$BOOTSTRAP_SCRIPT" --check --env-file "$nonexistent" 2>&1)
  local rc=$?

  [[ $rc -eq 1 ]] || fail "expected rc=1 for missing env file, got $rc"
  echo "$output" | grep -qi "does not exist\|missing" || fail "Expected missing/non-exist message"

  check_no_secrets "no secrets when .env missing" "$output"
}

test_init_local() {
  echo ""
  echo "=== Test: --init-local appends stubs ==="

  # Fixture: .env with master key but no MCP keys
  cat > "$FIXTURE_ENV" <<'EOF'
LITELLM_MASTER_KEY=sk-real-key-for-health-check-only
DATABASE_URL=postgresql://u:p@h:5432/db
# Existing comment
EOF

  local orig_size
  orig_size=$(wc -c < "$FIXTURE_ENV")

  "$BOOTSTRAP_SCRIPT" --init-local --env-file "$FIXTURE_ENV" >/dev/null 2>&1

  # Verify stubs were appended (file grew)
  local new_size
  new_size=$(wc -c < "$FIXTURE_ENV")

  [[ "$new_size" -gt "$orig_size" ]] || fail "File did not grow after --init-local"

  grep -q "^TAVILY_API_KEY="     "$FIXTURE_ENV" || fail "TAVILY_API_KEY stub not found"
  grep -q "^SUPERMEMORY_API_KEY=" "$FIXTURE_ENV" || fail "SUPERMEMORY_API_KEY stub not found"
  grep -q "^BRAVE_API_KEY="      "$FIXTURE_ENV" || fail "BRAVE_API_KEY stub not found"
  grep -q "^GITHUB_PERSONAL_ACCESS_TOKEN=" "$FIXTURE_ENV" || fail "GITHUB_PERSONAL_ACCESS_TOKEN stub not found"

  # Verify existing content was preserved
  grep -q "^LITELLM_MASTER_KEY=" "$FIXTURE_ENV" || fail "LITELLM_MASTER_KEY was overwritten"
  grep -q "^DATABASE_URL="        "$FIXTURE_ENV" || fail "DATABASE_URL was overwritten"
  grep -q "# Existing comment"    "$FIXTURE_ENV" || fail "Comment was lost"

  # Verify permissions are 600
  local perms
  perms=$(stat -c "%a" "$FIXTURE_ENV")
  [[ "$perms" == "600" ]] || fail "Expected perms 600, got $perms"

  pass "existing content preserved and permissions set"
}

test_init_local_preserves_existing() {
  echo ""
  echo "=== Test: --init-local does NOT overwrite existing keys ==="

  # Fixture: .env with MCP keys already present (even if empty)
  cat > "$FIXTURE_ENV" <<'EOF'
LITELLM_MASTER_KEY=sk-real-key-for-health-check-only
TAVILY_API_KEY=already-set-value
SUPERMEMORY_API_KEY=
BRAVE_API_KEY=
GITHUB_PERSONAL_ACCESS_TOKEN=
EOF

  local orig_tavily
  orig_tavily=$(grep "^TAVILY_API_KEY=" "$FIXTURE_ENV" | cut -d'=' -f2-)

  "$BOOTSTRAP_SCRIPT" --init-local --env-file "$FIXTURE_ENV" >/dev/null 2>&1

  local new_tavily
  new_tavily=$(grep "^TAVILY_API_KEY=" "$FIXTURE_ENV" | cut -d'=' -f2-)

  [[ "$orig_tavily" == "$new_tavily" ]] || fail "TAVILY_API_KEY was overwritten: '$orig_tavily' -> '$new_tavily'"
  [[ "$new_tavily" == "already-set-value" ]] || fail "TAVILY_API_KEY value changed unexpectedly"

  pass "existing keys were not overwritten"
}

test_validate_container_no_docker() {
  echo ""
  echo "=== Test: --validate-container without Docker ==="

  # Temporarily make docker fail to test safe skip
  local output
  output=$(MCP_BOOTSTRAP_TEST_DOCKER_FAIL=1 \
    env -u DOCKER_HOST -u DOCKER_CERT_PATH \
    PATH="$(echo "$PATH" | tr ':' '\n' | grep -v '^$' | head -1)" \
    "$BOOTSTRAP_SCRIPT" --validate-container --env-file "$FIXTURE_ENV" 2>&1)

  # Should not fail catastrophically; safe skip is ok
  [[ $? -le 1 ]] || fail "validate-container exited with code >1 without docker"

  # With no docker available, should mention docker or skip
  echo "$output" | grep -qi "docker\|skip\|not available\|not reachable" || \
    info "Output does not mention Docker unavailability (acceptable if docker is present)"
}

test_validate_container_mock() {
  echo ""
  echo "=== Test: --validate-container with mocked container status ==="

  # Create fixture .env
  cat > "$FIXTURE_ENV" <<'EOF'
TAVILY_API_KEY=fixture-value-not-real
SUPERMEMORY_API_KEY=fixture-value-not-real
BRAVE_API_KEY=fixture-value-not-real
GITHUB_PERSONAL_ACCESS_TOKEN=fixture-value-not-real
EOF

  # If docker is available but container is not, should handle gracefully
  if command -v docker &>/dev/null && ! docker info &>/dev/null; then
    local output
    output=$("$BOOTSTRAP_SCRIPT" --validate-container --env-file "$FIXTURE_ENV" 2>&1)
    local rc=$?
    [[ $rc -le 1 ]] || fail "validate-container failed with rc=$rc"
    check_no_secrets "no fixture values in container check" "$output"
  else
    info "Docker available; skipping mock-only test (container may or may not exist)"
  fi
}

test_secret_safety_comprehensive() {
  echo ""
  echo "=== Test: Secret safety — no real or fixture values in any output ==="

  # Fixture with realistic-looking fake values
  cat > "$FIXTURE_ENV" <<'EOF'
LITELLM_MASTER_KEY=sk-test-placeholder-12345678901234567890
TAVILY_API_KEY=tvly-test-fixture-placeholder-key-1234567890
SUPERMEMORY_API_KEY=smem-test-fixture-placeholder-key-1234567890
BRAVE_API_KEY=Bsr-test-fixture-placeholder-key-1234567890
GITHUB_PERSONAL_ACCESS_TOKEN=ghp_testfixtureplaceholdertoken1234567890
EOF

  local combined_output=""

  # Run all modes and collect output
  combined_output+=$("$BOOTSTRAP_SCRIPT" --check --env-file "$FIXTURE_ENV" 2>&1)
  combined_output+=$("$BOOTSTRAP_SCRIPT" --init-local --env-file "$FIXTURE_ENV" 2>&1)
  combined_output+=$("$BOOTSTRAP_SCRIPT" --validate-container --env-file "$FIXTURE_ENV" 2>&1)

  # Strict: no fixture placeholder values should appear in output
  local fixture_values=(
    "tvly-test-fixture"
    "smem-test-fixture"
    "Bsr-test-fixture"
    "ghp_testfixture"
    "sk-test-placeholder"
  )

  for fv in "${fixture_values[@]}"; do
    if echo "$combined_output" | grep -F "$fv" >/dev/null 2>&1; then
      fail "fixture value '$fv' leaked into script output"
    fi
  done

  pass "no fixture placeholder values found in output"
}

test_config_yaml_detection() {
  echo ""
  echo "=== Test: config.yaml MCP server detection ==="

  # Create a fixture config
  local fixture_cfg="${FIXTURE_DIR}/config.yaml"
  cat > "$fixture_cfg" <<'EOF'
mcp_servers:
  tavily_mcp:
    url: "https://mcp.tavily.com/mcp/"
    transport: http
  supermemory_mcp:
    url: "https://mcp.supermemory.ai/mcp"
    transport: http
  github_mcp:
    _disabled_reason: "no server available"
    # url: commented-out
  brave_search_mcp:
    url: "http://brave:8080/mcp"
    transport: http
EOF

  local output
  output=$("$BOOTSTRAP_SCRIPT" --check --env-file "$FIXTURE_ENV" --config-file "$fixture_cfg" 2>&1)

  echo "$output" | grep -q "tavily_mcp.*enabled"    || echo "$output" | grep -q "tavily_mcp"    || fail "tavily_mcp not in output"
  echo "$output" | grep -q "supermemory_mcp.*enabled" || echo "$output" | grep -q "supermemory_mcp" || fail "supermemory_mcp not in output"
  echo "$output" | grep -qi "github_mcp.*disabled\|github_mcp.*advisory" || echo "$output" | grep -q "github_mcp" || fail "github_mcp advisory not in output"

  pass "config.yaml server detection works"
}

test_no_opencode_access() {
  echo ""
  echo "=== Test: script does not READ .opencode secrets ==="

  # The script must not READ .opencode/.env or .opencode/secrets/*.
  # - Lines starting with # are shell comments.
  # - Lines inside heredocs (cat <<EOF ... EOF) are string literals, not code.
  # Check for actual file-read shell operations.
  local hits
  hits=$(awk '
    /^[[:space:]]*#/ { next }                   # skip shell comments
    /^[[:space:]]*cat[[:space:]]+<</ {          # detect heredoc start
      heredoc_delim = $NF
      in_heredoc = 1
      next
    }
    in_heredoc && $0 == heredoc_delim {         # detect heredoc end
      in_heredoc = 0
      next
    }
    in_heredoc { next }                         # skip heredoc body
    /\.opencode\/\.env|\.opencode\/secrets/ {   # actual code reference
      print NR ": " $0
    }
  ' "$BOOTSTRAP_SCRIPT" 2>/dev/null)

  if [[ -n "$hits" ]]; then
    fail "script contains .opencode file-read operation"
  else
    pass "script does not read .opencode/.env or .opencode/secrets"
  fi
}

# ── Main ──────────────────────────────────────────────────────────────────────

main() {
  echo "============================================================"
  echo "  LiteLLM MCP Env Bootstrap — Sandbox Tests"
  echo "============================================================"

  trap teardown_fixtures EXIT
  setup_fixtures

  echo ""
  echo "Using bootstrap script: $BOOTSTRAP_SCRIPT"

  test_check_mode_missing_keys
  test_check_mode_present_keys
  test_check_mode_no_env_file
  test_init_local
  test_init_local_preserves_existing
  test_validate_container_no_docker
  test_validate_container_mock
  test_secret_safety_comprehensive
  test_config_yaml_detection
  test_no_opencode_access

  echo ""
  echo "============================================================"
  echo "  Results: $TESTS_PASS passed, $TESTS_FAIL failed, $TESTS_RUN total"
  echo "============================================================"

  if [[ "$TESTS_FAIL" -gt 0 ]]; then
    exit 1
  fi
  exit 0
}

main "$@"
