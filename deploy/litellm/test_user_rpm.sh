#!/usr/bin/env bash
#
# test_user_rpm.sh — User-level RPM limit test script
# Tests that a shared virtual key enforces per-user RPM limits independently.
#

set -euo pipefail

# ---------------------------------------------------------------------------
# Environment defaults
# ---------------------------------------------------------------------------
LITELLM_BASE_URL="${LITELLM_BASE_URL:-http://localhost:4000}"
TEST_MODEL="${TEST_MODEL:?ERROR: TEST_MODEL must be set and not hardcoded}"
USER_RPM_LIMIT="${USER_RPM_LIMIT:-2}"
RUN_PROVIDER_CALLS="${RUN_PROVIDER_CALLS:-true}"
RUN_BOUNDARY_TEST="${RUN_BOUNDARY_TEST:-false}"

# ---------------------------------------------------------------------------
# Admin key — prefer LITELLM_API_KEY, fall back to LITELLM_MASTER_KEY
# ---------------------------------------------------------------------------
ADMIN_KEY="${LITELLM_API_KEY:-${LITELLM_MASTER_KEY:?ERROR: LITELLM_API_KEY or LITELLM_MASTER_KEY must be set}}"

# Mask for logging (print last 8 chars only)
mask_key() {
    local k="$1"
    if [ "${#k}" -le 8 ]; then
        echo "****"
    else
        echo "...${k: -8}"
    fi
}

ADMIN_KEY_MASKED="$(mask_key "$ADMIN_KEY")"

# ---------------------------------------------------------------------------
# Helper: curl wrapper that returns HTTP status only (no body) via stderr
# ---------------------------------------------------------------------------
http_status() {
    local method="${1:-GET}"
    local url="$2"
    shift 2
    curl -s -o /dev/null -w "%{http_code}" -X "$method" "$@" "$url"
}

# ---------------------------------------------------------------------------
# Helper: check if jq is available; setJQ to "" if absent
# ---------------------------------------------------------------------------
if command -v jq >/dev/null 2>&1; then
    JQ="jq"
else
    JQ=""
    echo "WARNING: jq not found — will use grep/sed for JSON parsing" >&2
fi

# ---------------------------------------------------------------------------
# Helper: parse JSON key with fallback if jq missing
# ---------------------------------------------------------------------------
json_get() {
    local key="$1"
    local json="$2"
    if [ -n "$JQ" ]; then
        echo "$json" | "$JQ" -r --arg k "$key" '.[$k]'
    else
        # crude fallback using sed: match "key":"value" or "key": "value"
        echo "$json" | sed -n 's/.*"'"$key"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1
    fi
}

# ---------------------------------------------------------------------------
# Banner
# ---------------------------------------------------------------------------
echo "=============================================="
echo "User-level RPM PoC Test"
echo "=============================================="
echo "LITELLM_BASE_URL : $LITELLM_BASE_URL"
echo "TEST_MODEL       : $TEST_MODEL"
echo "USER_RPM_LIMIT   : $USER_RPM_LIMIT"
echo "ADMIN_KEY        : $ADMIN_KEY_MASKED"
echo "RUN_PROVIDER_CALLS: $RUN_PROVIDER_CALLS"
echo "RUN_BOUNDARY_TEST : ${RUN_BOUNDARY_TEST:-false}"
echo "jq available     : $(command -v jq >/dev/null 2>&1 && echo yes || echo no)"
echo "=============================================="

# ---------------------------------------------------------------------------
# 1. Create budget with rpm_limit
# ---------------------------------------------------------------------------
echo ""
echo "[1/9] Creating budget with rpm_limit=$USER_RPM_LIMIT ..."

BUDGET_RESP=$(curl -s -X POST "$LITELLM_BASE_URL/budget/new" \
    -H "Authorization: Bearer $ADMIN_KEY" \
    -H "Content-Type: application/json" \
    -d "{\"rpm_limit\": $USER_RPM_LIMIT}")

BUDGET_ID=$(json_get "budget_id" "$BUDGET_RESP")

if [ -z "$BUDGET_ID" ] || [ "$BUDGET_ID" = "null" ]; then
    echo "ERROR: Failed to create budget. Response: $BUDGET_RESP" >&2
    exit 1
fi
echo "SUCCESS: budget_id=$BUDGET_ID"

# ---------------------------------------------------------------------------
# 2. Create customer user_a
# ---------------------------------------------------------------------------
echo ""
echo "[2/9] Creating customer user_a ..."

USER_A_RESP=$(curl -s -X POST "$LITELLM_BASE_URL/customer/new" \
    -H "Authorization: Bearer $ADMIN_KEY" \
    -H "Content-Type: application/json" \
    -d "{\"budget_id\": \"$BUDGET_ID\", \"user_id\": \"user_a\"}")

USER_A_ID=$(json_get "user_id" "$USER_A_RESP")

if [ -z "$USER_A_ID" ] || [ "$USER_A_ID" = "null" ]; then
    echo "ERROR: Failed to create customer user_a. Response: $USER_A_RESP" >&2
    exit 1
fi
echo "SUCCESS: user_a created (user_id=$USER_A_ID)"

# ---------------------------------------------------------------------------
# 3. Create customer user_b
# ---------------------------------------------------------------------------
echo ""
echo "[3/9] Creating customer user_b ..."

USER_B_RESP=$(curl -s -X POST "$LITELLM_BASE_URL/customer/new" \
    -H "Authorization: Bearer $ADMIN_KEY" \
    -H "Content-Type: application/json" \
    -d "{\"budget_id\": \"$BUDGET_ID\", \"user_id\": \"user_b\"}")

USER_B_ID=$(json_get "user_id" "$USER_B_RESP")

if [ -z "$USER_B_ID" ] || [ "$USER_B_ID" = "null" ]; then
    echo "ERROR: Failed to create customer user_b. Response: $USER_B_RESP" >&2
    exit 1
fi
echo "SUCCESS: user_b created (user_id=$USER_B_ID)"

# ---------------------------------------------------------------------------
# 4. Generate shared virtual key
# ---------------------------------------------------------------------------
echo ""
echo "[4/9] Generating shared virtual key for model=$TEST_MODEL ..."

VKEY_RESP=$(curl -s -X POST "$LITELLM_BASE_URL/key/generate" \
    -H "Authorization: Bearer $ADMIN_KEY" \
    -H "Content-Type: application/json" \
    -d "{
        \"models\": [\"$TEST_MODEL\"],
        \"duration\": \"30d\"
    }")

VKEY=$(json_get "key" "$VKEY_RESP")

if [ -z "$VKEY" ] || [ "$VKEY" = "null" ]; then
    echo "ERROR: Failed to generate virtual key. Response: $VKEY_RESP" >&2
    exit 1
fi

VKEY_MASKED="$(mask_key "$VKEY")"
echo "SUCCESS: virtual key generated: $VKEY_MASKED"

# ---------------------------------------------------------------------------
# 5. Call /v1/chat/completions with user_a, USER_RPM_LIMIT+1 times
#    Expect last call to be rate-limited (non-2xx)
# ---------------------------------------------------------------------------
echo ""
echo "[5/9] Calling /v1/chat/completions with user_a $((USER_RPM_LIMIT + 1)) times ..."

if [ "$RUN_PROVIDER_CALLS" != "true" ]; then
    echo "SKIPPED: RUN_PROVIDER_CALLS is not true"
else
    for i in $(seq 1 $((USER_RPM_LIMIT + 1))); do
        STATUS=$(http_status POST "$LITELLM_BASE_URL/v1/chat/completions" \
            -H "Authorization: Bearer $VKEY" \
            -H "Content-Type: application/json" \
            -d "{
                \"model\": \"$TEST_MODEL\",
                \"messages\": [{\"role\": \"user\", \"content\": \"test $i\"}],
                \"user\": \"user_a\"
            }")

        echo "  call $i: HTTP $STATUS"

        if [ "$i" -le "$USER_RPM_LIMIT" ]; then
            if [ "$STATUS" -ge 200 ] && [ "$STATUS" -lt 300 ]; then
                : # expected success
            else
                echo "FAIL: call $i expected 2xx but got $STATUS" >&2
                exit 1
            fi
        else
            # Last call should be rate-limited
            if [ "$STATUS" -ge 200 ] && [ "$STATUS" -lt 300 ]; then
                echo "FAIL: call $i expected rate-limited (non-2xx) but got $STATUS" >&2
                exit 1
            else
                echo "  => correctly rate-limited (HTTP $STATUS)"
            fi
        fi
    done
    echo "SUCCESS: user_a rate-limited after $USER_RPM_LIMIT calls"
fi

# ---------------------------------------------------------------------------
# 6. Call /v1/chat/completions with user_b, expect 2xx
# ---------------------------------------------------------------------------
echo ""
echo "[6/9] Calling /v1/chat/completions with user_b once (should succeed) ..."

if [ "$RUN_PROVIDER_CALLS" != "true" ]; then
    echo "SKIPPED: RUN_PROVIDER_CALLS is not true"
else
    STATUS=$(http_status POST "$LITELLM_BASE_URL/v1/chat/completions" \
        -H "Authorization: Bearer $VKEY" \
        -H "Content-Type: application/json" \
        -d "{
            \"model\": \"$TEST_MODEL\",
            \"messages\": [{\"role\": \"user\", \"content\": \"user_b test\"}],
            \"user\": \"user_b\"
        }")

    echo "  HTTP $STATUS"

    if [ "$STATUS" -ge 200 ] && [ "$STATUS" -lt 300 ]; then
        echo "SUCCESS: user_b call succeeded (HTTP $STATUS)"
    else
        echo "FAIL: user_b expected 2xx but got $STATUS" >&2
        exit 1
    fi
fi

# ---------------------------------------------------------------------------
# 7. Call without user parameter, expect non-2xx (enforce_user_param: true)
# ---------------------------------------------------------------------------
echo ""
echo "[7/9] Calling /v1/chat/completions without user parameter (expect failure) ..."

if [ "$RUN_PROVIDER_CALLS" != "true" ]; then
    echo "SKIPPED: RUN_PROVIDER_CALLS is not true"
else
    STATUS=$(http_status POST "$LITELLM_BASE_URL/v1/chat/completions" \
        -H "Authorization: Bearer $VKEY" \
        -H "Content-Type: application/json" \
        -d "{
            \"model\": \"$TEST_MODEL\",
            \"messages\": [{\"role\": \"user\", \"content\": \"no user test\"}]
        }")

    echo "  HTTP $STATUS"

    if [ "$STATUS" -ge 200 ] && [ "$STATUS" -lt 300 ]; then
        echo "FAIL: missing user call expected non-2xx but got $STATUS" >&2
        exit 1
    else
        echo "SUCCESS: correctly rejected missing user parameter (HTTP $STATUS)"
    fi
fi

# ---------------------------------------------------------------------------
# 8. Boundary test: wait for rate window to reset, then verify user_a recovers
# ---------------------------------------------------------------------------
RATE_WINDOW_WAIT_SECONDS="${RATE_WINDOW_WAIT_SECONDS:-70}"

echo ""
echo "[8/9] Boundary test: waiting ${RATE_WINDOW_WAIT_SECONDS}s for rate window to reset ..."

if [ "$RUN_PROVIDER_CALLS" != "true" ]; then
    echo "SKIPPED: RUN_PROVIDER_CALLS is not true"
elif [ "${RUN_BOUNDARY_TEST:-false}" != "true" ]; then
    echo "SKIPPED: RUN_BOUNDARY_TEST is not true"
else
    echo "  Waiting ${RATE_WINDOW_WAIT_SECONDS} seconds (rate window = 60s, grace = 10s) ..."
    sleep "$RATE_WINDOW_WAIT_SECONDS"

    echo "  Calling /v1/chat/completions with user_a after rate window reset ..."
    STATUS=$(http_status POST "$LITELLM_BASE_URL/v1/chat/completions" \
        -H "Authorization: Bearer $VKEY" \
        -H "Content-Type: application/json" \
        -d "{
            \"model\": \"$TEST_MODEL\",
            \"messages\": [{\"role\": \"user\", \"content\": \"after rate window reset\"}],
            \"user\": \"user_a\"
        }")

    echo "  HTTP $STATUS"

    if [ "$STATUS" -ge 200 ] && [ "$STATUS" -lt 300 ]; then
        echo "SUCCESS: user_a recovered after rate window reset (HTTP $STATUS)"
    else
        echo "FAIL: user_a expected 2xx after rate window reset but got $STATUS" >&2
        exit 1
    fi
fi

# ---------------------------------------------------------------------------
# 9. Summary
# ---------------------------------------------------------------------------
echo ""
echo "[9/9] All tests passed!"
echo "=============================================="
echo "Summary"
echo "=============================================="
echo "budget_id   : $BUDGET_ID"
echo "user_a      : $USER_A_ID"
echo "user_b      : $USER_B_ID"
echo "virtual key : $VKEY_MASKED"
echo "RPM limit   : $USER_RPM_LIMIT per user"
echo ""
echo "Test completed successfully at $(date -Iseconds)"
exit 0
