#!/bin/bash
# =============================================================================
# GCP Vertex AI 權限測試腳本
# =============================================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}ℹ${NC} $1"; }
log_success() { echo -e "${GREEN}✓${NC} $1"; }
log_warn() { echo -e "${YELLOW}⚠${NC} $1"; }
log_error() { echo -e "${RED}✗${NC} $1"; }

echo -e "${BLUE}================================================${NC}"
echo -e "${BLUE}  GCP Vertex AI 權限測試${NC}"
echo -e "${BLUE}================================================${NC}"
echo ""

# 檢查環境
if [[ -z "$GOOGLE_APPLICATION_CREDENTIALS" ]]; then
    log_warn "未設定 GOOGLE_APPLICATION_CREDENTIALS 環境變數"
    log_info "請先執行："
    echo "  export GOOGLE_APPLICATION_CREDENTIALS=/path/to/your-key.json"
    echo "  gcloud auth activate-service-account --key-file=\$GOOGLE_APPLICATION_CREDENTIALS"
    exit 1
fi

log_info "使用 Credential: $GOOGLE_APPLICATION_CREDENTIALS"
echo ""

# 測試 1: 驗證 gcloud 登入
echo -e "${BLUE}[測試 1/4]${NC} 檢查 gcloud 認證..."
if gcloud auth list --filter=status:ACTIVE --format="value(account)" | grep -q "@"; then
    ACTIVE_ACCOUNT=$(gcloud auth list --filter=status:ACTIVE --format="value(account)" | head -1)
    log_success "已登入: $ACTIVE_ACCOUNT"
else
    log_error "未登入，請執行 gcloud auth activate-service-account"
    exit 1
fi
echo ""

# 測試 2: 檢查專案權限
echo -e "${BLUE}[測試 2/4]${NC} 檢查專案存取權限..."
if gcloud projects describe datasciencellmprod &>/dev/null; then
    log_success "可以存取專案 datasciencellmprod"
else
    log_error "無法存取專案，檢查專案 ID 是否正確"
    exit 1
fi
echo ""

# 測試 3: 檢查 IAM 角色
echo -e "${BLUE}[測試 3/4]${NC} 檢查 IAM 角色..."
log_info "目前的 IAM 綁定："
gcloud projects get-iam-policy datasciencellmprod \
    --flatten="bindings[].members" \
    --format="table(bindings.role,bindings.members)" \
    --filter="bindings.members:$(gcloud config get-value account)" 2>/dev/null || \
    log_warn "無法列出 IAM 政策（可能需要更多權限）"

echo ""
log_info "需要的角色："
echo "  - roles/aiplatform.user (Vertex AI User)"
echo "  - 或 roles/aiplatform.admin (Vertex AI Administrator)"
echo ""

# 測試 4: 直接測試 Vertex AI API
echo -e "${BLUE}[測試 4/4]${NC} 測試 Vertex AI API 呼叫..."
log_info "嘗試呼叫 Gemini 1.5 Pro..."

# 使用 curl 直接測試 API
PROJECT_ID="datasciencellmprod"
LOCATION="asia-east1"
MODEL="gemini-1.5-pro"

# 取得 access token
ACCESS_TOKEN=$(gcloud auth print-access-token 2>/dev/null)

if [[ -z "$ACCESS_TOKEN" ]]; then
    log_error "無法取得 Access Token"
    exit 1
fi

# 測試 API 呼叫
RESPONSE=$(curl -s -X POST \
    "https://${LOCATION}-aiplatform.googleapis.com/v1/projects/${PROJECT_ID}/locations/${LOCATION}/publishers/google/models/${MODEL}:generateContent" \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    -H "Content-Type: application/json" \
    -d '{
        "contents": [{
            "role": "user",
            "parts": [{"text": "Hello, test connection"}]
        }]
    }' 2>&1)

if echo "$RESPONSE" | grep -q "error"; then
    log_error "API 呼叫失敗"
    echo "$RESPONSE" | python3 -m json.tool 2>/dev/null || echo "$RESPONSE"
    echo ""
    log_warn "常見解決方案："
    echo "  1. 確認已啟用 Vertex AI API"
    echo "     https://console.cloud.google.com/apis/library/aiplatform.googleapis.com"
    echo "  2. 添加 Vertex AI User 角色"
    echo "     gcloud projects add-iam-policy-binding ${PROJECT_ID} \\"
    echo "       --member=\"serviceAccount:\$(gcloud config get-value account)\" \\"
    echo "       --role=\"roles/aiplatform.user\""
    exit 1
else
    log_success "API 呼叫成功！"
    echo "$RESPONSE" | python3 -m json.tool 2>/dev/null | head -20
fi

echo ""
echo -e "${GREEN}================================================${NC}"
echo -e "${GREEN}  所有測試通過！權限配置正確${NC}"
echo -e "${GREEN}================================================${NC}"
