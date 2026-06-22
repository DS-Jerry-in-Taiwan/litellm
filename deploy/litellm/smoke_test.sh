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
