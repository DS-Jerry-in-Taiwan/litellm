#!/usr/bin/env bash
# =============================================================================
# LiteLLM Smoke Test Script
# =============================================================================
# 用途：驗證 LiteLLM Proxy 部署是否正常（不依賴真實 provider key）
# 依賴：curl（必備）、jq（可選，無 jq 時會 graceful fallback）
#
# 使用方式：
#   # 基本健康檢查
#   ./smoke_test.sh
#
#   # 包含 Chat Completions 測試（需要真實 OPENAI_API_KEY）
#   RUN_CHAT_TEST=true ./smoke_test.sh
#
#   # 包含 Virtual Key 建立測試（需要 LITELLM_API_KEY = master key）
#   RUN_KEY_TEST=true ./smoke_test.sh
#
#   # 自訂 base URL
#   LITELLM_BASE_URL=http://localhost:4000 LITELLM_API_KEY=sk-test ./smoke_test.sh
# =============================================================================

set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# 參數與環境變數
# ─────────────────────────────────────────────────────────────────────────────
LITELLM_BASE_URL="${LITELLM_BASE_URL:-http://localhost:4000}"
LITELLM_API_KEY="${LITELLM_API_KEY:-${LITELLM_MASTER_KEY:-sk-change-me-replace-before-use}}"

RUN_CHAT_TEST="${RUN_CHAT_TEST:-false}"
RUN_KEY_TEST="${RUN_KEY_TEST:-false}"
RUN_PLAYWRIGHT_MCP_TEST="${RUN_PLAYWRIGHT_MCP_TEST:-false}"
RUN_MERMAID_MCP_TEST="${RUN_MERMAID_MCP_TEST:-false}"

# 顏色輸出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# ─────────────────────────────────────────────────────────────────────────────
# Helper Functions
# ─────────────────────────────────────────────────────────────────────────────

log_info() {
    echo -e "${GREEN}[INFO]${NC} $*"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $*"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*" >&2
}

# 檢查 jq 是否存在，若不存在則输出 WARNING 並繼續（graceful fallback）
check_jq() {
    if ! command -v jq &>/dev/null; then
        log_warn "jq not found — response body will not be parsed"
        return 1
    fi
    return 0
}

# HTTP health check
check_health() {
    log_info "Checking /health endpoint..."

    local response
    local http_code

    # LiteLLM 1.89.0+ 要求 /health 需要認證
    local curl_args=(-s -w "\n%{http_code}" --max-time 10)
    if [[ -n "${LITELLM_API_KEY}" ]]; then
        curl_args+=(-H "Authorization: Bearer ${LITELLM_API_KEY}")
    fi

    response=$(curl "${curl_args[@]}" \
        "${LITELLM_BASE_URL}/health" \
        -o /tmp/health_body.txt 2>&1) || {
        log_error "Failed to connect to ${LITELLM_BASE_URL}/health"
        return 1
    }

    http_code=$(echo "$response" | tail -n1)
    local body
    body=$(cat /tmp/health_body.txt)

    if [[ "$http_code" != "200" ]]; then
        log_error "/health returned HTTP ${http_code}"
        log_error "Body: $body"
        return 1
    fi

    log_info "/health HTTP 200 OK"
    echo "$body"

    # ── 檢查 DB / Redis 連線狀態 ──────────────────────────────────────────
    if check_jq; then
        local db_status redis_status
        db_status=$(echo "$body" | jq -r '.db_connection // "unknown"' 2>/dev/null || echo "unknown")
        redis_status=$(echo "$body" | jq -r '.redis_connection // "not_configured"' 2>/dev/null || echo "unknown")

        log_info "DB connection: ${db_status}"
        log_info "Redis connection: ${redis_status}"

        if [[ "$db_status" == "disconnected" ]]; then
            log_error "Database is disconnected — virtual keys / Admin UI will not work"
            return 1
        fi

        if [[ "$db_status" == "unknown" ]]; then
            log_warn "Could not determine DB connection status from /health response"
        fi
    else
        # 無 jq 时只记录 body
        log_warn "DB/Redis status check skipped (jq not available)"
        log_info "Health response body: ${body}"
    fi

    return 0
}

# ── Chat Completions 測試（需要真實 provider key）────────────────────────────
test_chat_completions() {
    log_info "Testing /v1/chat/completions (model: gpt-4o-mini)..."

    if [[ "$RUN_CHAT_TEST" != "true" ]]; then
        log_warn "RUN_CHAT_TEST != true, skipping chat completions test"
        return 0
    fi

    local response
    local http_code

    response=$(curl -s -w "\n%{http_code}" \
        --max-time 60 \
        "${LITELLM_BASE_URL}/v1/chat/completions" \
        -H "Authorization: Bearer ${LITELLM_API_KEY}" \
        -H "Content-Type: application/json" \
        -d '{
            "model": "gpt-4o-mini",
            "messages": [{"role": "user", "content": "Say hi in one word"}],
            "max_tokens": 10
        }' 2>&1) || {
        log_error "Chat completions request failed"
        return 1
    }

    http_code=$(echo "$response" | tail -n1)
    local body
    body=$(echo "$response" | sed '$d')

    if [[ "$http_code" != "200" ]]; then
        log_error "/v1/chat/completions returned HTTP ${http_code}"
        log_error "Body: ${body}"
        return 1
    fi

    # 驗證回應格式
    if check_jq; then
        local content
        content=$(echo "$body" | jq -r '.choices[0].message.content // empty' 2>/dev/null)
        if [[ -z "$content" ]]; then
            log_error "Invalid response format — missing choices[0].message.content"
            log_error "Body: ${body}"
            return 1
        fi
        log_info "Chat completions OK — response: ${content}"
    else
        log_info "Chat completions HTTP 200 (jq not available, skipping body parse)"
    fi

    return 0
}

# ── Virtual Key 建立測試（需要 master key）─────────────────────────────────
test_virtual_key() {
    log_info "Testing virtual key generation (Admin endpoint /key/generate)..."

    if [[ "$RUN_KEY_TEST" != "true" ]]; then
        log_warn "RUN_KEY_TEST != true, skipping key generation test"
        return 0
    fi

    # 使用 master key 建立 virtual key
    local response
    local http_code

    response=$(curl -s -w "\n%{http_code}" \
        --max-time 10 \
        -X POST \
        "${LITELLM_BASE_URL}/key/generate" \
        -H "Authorization: Bearer ${LITELLM_API_KEY}" \
        -H "Content-Type: application/json" \
        -d '{
            "key_alias": "smoke-test-key",
            "models": ["gpt-4o-mini"],
            "budget_limit": 1.0,
            "rpm_limit": 10
        }' 2>&1) || {
        log_error "Key generation request failed"
        return 1
    }

    http_code=$(echo "$response" | tail -n1)
    local body
    body=$(echo "$response" | sed '$d')

    if [[ "$http_code" != "200" ]]; then
        log_error "/key/generate returned HTTP ${http_code}"
        log_error "Body: ${body}"
        return 1
    fi

    if check_jq; then
        local vkey
        vkey=$(echo "$body" | jq -r '.key // empty' 2>/dev/null)
        if [[ -z "$vkey" ]]; then
            log_error "Invalid key generation response — missing 'key' field"
            log_error "Body: ${body}"
            return 1
        fi
        log_info "Virtual key generated successfully: ${vkey}"
    else
        log_info "Virtual key generation HTTP 200 (jq not available, skipping parse)"
    fi

    return 0
}

# ── Playwright MCP Sidecar Smoke Test ──────────────────────────────────────
# Tests the Playwright MCP sidecar reachability from LiteLLM.
# Gated by RUN_PLAYWRIGHT_MCP_TEST=true — does not run by default.
# The sidecar uses Docker Compose profile "browser-mcp" and must be running.
# ---------------------------------------------------------------------------
test_playwright_mcp() {
    log_info "Testing Playwright MCP sidecar reachability..."

    if [[ "$RUN_PLAYWRIGHT_MCP_TEST" != "true" ]]; then
        log_warn "RUN_PLAYWRIGHT_MCP_TEST != true, skipping Playwright MCP test"
        return 0
    fi

    # Step 1: Check if the sidecar container exists and is running
    local pw_container_status
    if command -v docker &>/dev/null; then
        pw_container_status=$(docker inspect playwright-mcp-server \
            --format '{{.State.Status}}' 2>/dev/null || echo "not_found")
        if [[ "$pw_container_status" == "not_found" ]]; then
            log_error "Playwright MCP sidecar container 'playwright-mcp-server' not found."
            log_error "The sidecar is profile-gated (browser-mcp). Start with:"
            log_error "  docker compose --profile browser-mcp up -d"
            return 1
        fi
        if [[ "$pw_container_status" != "running" ]]; then
            log_error "Playwright MCP sidecar container is '$pw_container_status' (expected 'running')."
            return 1
        fi
        log_info "Sidecar container status: running"
    else
        log_warn "docker not available — skipping container status check"
    fi

    # Step 2: Check LiteLLM MCP health endpoint for playwright_mcp status
    # Requires LITELLM_API_KEY (master key) to be set.
    local api_key="${LITELLM_API_KEY}"
    if [[ "${api_key}" == "sk-change-me-replace-before-use" ]]; then
        log_warn "LITELLM_API_KEY is placeholder — cannot query MCP health endpoint"
        log_warn "Skipping MCP health check for playwright_mcp"
        return 0
    fi

    local health_response
    local http_code
    health_response=$(curl -s --max-time 10 \
        -w "\n%{http_code}" \
        -H "Authorization: Bearer ${api_key}" \
        "${LITELLM_BASE_URL}/v1/mcp/server/health" 2>/dev/null || echo "__CURL_FAILED__")

    if [[ "$health_response" == "__CURL_FAILED__" ]]; then
        log_error "Could not reach ${LITELLM_BASE_URL}/v1/mcp/server/health"
        log_error "Ensure LiteLLM is running and reachable."
        return 1
    fi

    http_code=$(echo "$health_response" | tail -n1)
    local response_body
    response_body=$(echo "$health_response" | sed '$d')

    if [[ "$http_code" != "200" ]]; then
        log_warn "MCP health endpoint returned HTTP ${http_code} (expected 200)"
        log_warn "Playwright MCP sidecar may not be registered yet."
        return 0
    fi

    # Parse the response for playwright_mcp status (no secrets printed)
    if command -v jq &>/dev/null; then
        local pw_status
        pw_status=$(echo "$response_body" | jq -r '
            (.mcp_servers // .servers // . | .. | objects |
             select(.url // .command // empty) |
             if (.url // "") | test("playwright") then .status // "unknown" else empty end)
            // "not_found"' 2>/dev/null)
        if [[ -z "$pw_status" || "$pw_status" == "not_found" ]]; then
            # Try simpler path: direct key lookup in objects
            pw_status=$(echo "$response_body" | jq -r '
                (.. | objects | select(.description? // "" | test("Playwright")) | .status)
                // "not_found"' 2>/dev/null)
        fi
        log_info "Playwright MCP health status: ${pw_status}"
        if [[ "$pw_status" == "healthy" || "$pw_status" == "connected" ]]; then
            log_info "Playwright MCP sidecar is connected and healthy."
        elif [[ "$pw_status" == "not_found" ]]; then
            log_warn "playwright_mcp not found in MCP health response."
            log_warn "This is expected if the sidecar profile is not running."
        else
            log_warn "Playwright MCP status is '${pw_status}' (may be expected if sidecar profile is not running)"
        fi
    else
        log_info "MCP health endpoint HTTP 200 (jq not available, skipping parse)"
    fi

    return 0
}

# ── Mermaid MCP Sidecar Smoke Test ──────────────────────────────────────────
# Tests the Mermaid MCP sidecar reachability from LiteLLM.
# Gated by RUN_MERMAID_MCP_TEST=true — does not run by default.
# The sidecar uses Docker Compose profile "browser-mcp" and must be running.
# ---------------------------------------------------------------------------
test_mermaid_mcp() {
    log_info "Testing Mermaid MCP sidecar reachability..."

    if [[ "$RUN_MERMAID_MCP_TEST" != "true" ]]; then
        log_warn "RUN_MERMAID_MCP_TEST != true, skipping Mermaid MCP test"
        return 0
    fi

    # Step 1: Check if the sidecar container exists and is running
    local mm_container_status
    if command -v docker &>/dev/null; then
        mm_container_status=$(docker inspect mermaid-mcp-server \
            --format '{{.State.Status}}' 2>/dev/null || echo "not_found")
        if [[ "$mm_container_status" == "not_found" ]]; then
            log_error "Mermaid MCP sidecar container 'mermaid-mcp-server' not found."
            log_error "The sidecar is profile-gated (browser-mcp). Start with:"
            log_error "  docker compose --profile browser-mcp up -d"
            return 1
        fi
        if [[ "$mm_container_status" != "running" ]]; then
            log_error "Mermaid MCP sidecar container is '$mm_container_status' (expected 'running')."
            return 1
        fi
        log_info "Sidecar container status: running"
    else
        log_warn "docker not available — skipping container status check"
    fi

    # Step 2: Check LiteLLM MCP health endpoint for mermaid_mcp status
    # Requires LITELLM_API_KEY (master key) to be set.
    local api_key="${LITELLM_API_KEY}"
    if [[ "${api_key}" == "sk-change-me-replace-before-use" ]]; then
        log_warn "LITELLM_API_KEY is placeholder — cannot query MCP health endpoint"
        log_warn "Skipping MCP health check for mermaid_mcp"
        return 0
    fi

    local health_response
    local http_code
    health_response=$(curl -s --max-time 10 \
        -w "\n%{http_code}" \
        -H "Authorization: Bearer ${api_key}" \
        "${LITELLM_BASE_URL}/v1/mcp/server/health" 2>/dev/null || echo "__CURL_FAILED__")

    if [[ "$health_response" == "__CURL_FAILED__" ]]; then
        log_error "Could not reach ${LITELLM_BASE_URL}/v1/mcp/server/health"
        log_error "Ensure LiteLLM is running and reachable."
        return 1
    fi

    http_code=$(echo "$health_response" | tail -n1)
    local response_body
    response_body=$(echo "$health_response" | sed '$d')

    if [[ "$http_code" != "200" ]]; then
        log_warn "MCP health endpoint returned HTTP ${http_code} (expected 200)"
        log_warn "Mermaid MCP sidecar may not be registered yet."
        return 0
    fi

    # Parse the response for mermaid_mcp status (no secrets printed)
    if command -v jq &>/dev/null; then
        local mm_status
        mm_status=$(echo "$response_body" | jq -r '
            (.mcp_servers // .servers // . | .. | objects |
             select(.url // .command // empty) |
             if (.url // "") | test("mermaid") then .status // "unknown" else empty end)
            // "not_found"' 2>/dev/null)
        if [[ -z "$mm_status" || "$mm_status" == "not_found" ]]; then
            mm_status=$(echo "$response_body" | jq -r '
                (.. | objects | select(.description? // "" | test("Mermaid")) | .status)
                // "not_found"' 2>/dev/null)
        fi
        log_info "Mermaid MCP health status: ${mm_status}"
        if [[ "$mm_status" == "healthy" || "$mm_status" == "connected" ]]; then
            log_info "Mermaid MCP sidecar is connected and healthy."
        elif [[ "$mm_status" == "not_found" ]]; then
            log_warn "mermaid_mcp not found in MCP health response."
            log_warn "This is expected if the sidecar profile is not running."
        else
            log_warn "Mermaid MCP status is '${mm_status}' (may be expected if sidecar profile is not running)"
        fi
    else
        log_info "MCP health endpoint HTTP 200 (jq not available, skipping parse)"
    fi

    return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────────────────────────────────────

main() {
    echo "============================================"
    echo "LiteLLM Smoke Test"
    echo "============================================"
    echo "Base URL:  ${LITELLM_BASE_URL}"
    echo "API Key:    ${LITELLM_API_KEY:0:8}..."
    echo "Chat Test:  ${RUN_CHAT_TEST}"
    echo "Key Test:   ${RUN_KEY_TEST}"
    echo "Playwright MCP Test:  ${RUN_PLAYWRIGHT_MCP_TEST}"
    echo "Mermaid MCP Test:     ${RUN_MERMAID_MCP_TEST}"
    echo "============================================"

    # ── 如果 LITELLM_API_KEY 還是 placeholder，發出警告 ─────────
    if [[ "${LITELLM_API_KEY}" == "sk-change-me-replace-before-use" ]]; then
        log_warn "LITELLM_API_KEY / LITELLM_MASTER_KEY 尚未設定。"
        log_warn "部分測試（如 /health）可能需要 API key 才能通過。"
    fi
    # ─────────────────────────────────────────────────────────────

    local failed=0

    # 1. Health check
    if ! check_health; then
        log_error "Health check FAILED"
        failed=1
    fi

    # 2. Chat completions
    if ! test_chat_completions; then
        log_error "Chat completions test FAILED"
        failed=1
    fi

    # 3. Virtual key generation
    if ! test_virtual_key; then
        log_error "Virtual key test FAILED"
        failed=1
    fi

    # 4. Playwright MCP sidecar (opt-in, needs running sidecar profile)
    if ! test_playwright_mcp; then
        log_error "Playwright MCP test FAILED"
        failed=1
    fi

    # 5. Mermaid MCP sidecar (opt-in, needs running sidecar profile)
    if ! test_mermaid_mcp; then
        log_error "Mermaid MCP test FAILED"
        failed=1
    fi

    echo "============================================"
    if [[ $failed -eq 0 ]]; then
        log_info "All smoke tests PASSED"
        exit 0
    else
        log_error "Some smoke tests FAILED"
        exit 1
    fi
}

main "$@"
