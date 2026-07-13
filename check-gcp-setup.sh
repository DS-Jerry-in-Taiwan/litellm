#!/bin/bash
# =============================================================================
# GCP 專案 Vertex AI 狀態檢查腳本
# 檢查項目：
#   1. 計費帳號狀態
#   2. Vertex AI API 啟用狀態
#   3. 服務帳號權限
#   4. Model Garden 存取權
# =============================================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

log_info() { echo -e "${BLUE}ℹ${NC} $1"; }
log_success() { echo -e "${GREEN}✓${NC} $1"; }
log_warn() { echo -e "${YELLOW}⚠${NC} $1"; }
log_error() { echo -e "${RED}✗${NC} $1"; }
log_section() { echo -e "\n${BOLD}${BLUE}▶ $1${NC}"; }

echo -e "${BOLD}${BLUE}"
echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║     GCP Vertex AI 專案狀態檢查                                ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo -e "${NC}"

PROJECT_ID="${1:-datasciencellmprod}"
log_info "檢查專案: ${PROJECT_ID}"
echo ""

# 檢查 gcloud 登入
if ! gcloud auth list --filter=status:ACTIVE --format="value(account)" | grep -q "@"; then
    log_error "請先登入 gcloud"
    echo "  gcloud auth login"
    exit 1
fi

# 設定專案
gcloud config set project ${PROJECT_ID} >/dev/null 2>&1

# ═════════════════════════════════════════════════════════════════
log_section "1. 計費帳號狀態"
# ═════════════════════════════════════════════════════════════════

BILLING_INFO=$(gcloud billing projects describe ${PROJECT_ID} --format="value(billingAccountName,billingEnabled)" 2>/dev/null || echo "")

if [[ -z "$BILLING_INFO" ]]; then
    log_error "❌ 沒有綁定計費帳號"
    echo "   前往: https://console.cloud.google.com/billing?project=${PROJECT_ID}"
    echo "   後果: 無法使用任何付費服務（包括 Vertex AI）"
else
    BILLING_ACCOUNT=$(echo "$BILLING_INFO" | cut -f1)
    BILLING_ENABLED=$(echo "$BILLING_INFO" | cut -f2)
    
    if [[ "$BILLING_ENABLED" == "True" ]]; then
        log_success "✅ 計費帳號已啟用"
        echo "   帳號: ${BILLING_ACCOUNT}"
    else
        log_warn "⚠️  計費帳號已停用"
        echo "   帳號: ${BILLING_ACCOUNT}"
        echo "   狀態: 需要重新啟用"
    fi
fi

# ═════════════════════════════════════════════════════════════════
log_section "2. API 啟用狀態"
# ═════════════════════════════════════════════════════════════════

APIS=(
    "aiplatform.googleapis.com:Vertex AI API"
    "generativelanguage.googleapis.com:Generative Language API (Gemini)"
)

for api_info in "${APIS[@]}"; do
    IFS=':' read -r api_name api_desc <<< "$api_info"
    
    STATE=$(gcloud services list --enabled --format="value(config.name)" 2>/dev/null | grep "^${api_name}$" || echo "")
    
    if [[ -n "$STATE" ]]; then
        log_success "✅ ${api_desc} 已啟用"
    else
        log_error "❌ ${api_desc} 未啟用"
        echo "   啟用指令: gcloud services enable ${api_name} --project=${PROJECT_ID}"
    fi
done

# ═════════════════════════════════════════════════════════════════
log_section "3. 服務帳號權限"
# ═════════════════════════════════════════════════════════════════

SERVICE_ACCOUNT="litellm-project@${PROJECT_ID}.iam.gserviceaccount.com"

log_info "檢查服務帳號: ${SERVICE_ACCOUNT}"

# 檢查服務帳號是否存在
if gcloud iam service-accounts describe ${SERVICE_ACCOUNT} >/dev/null 2>&1; then
    log_success "✅ 服務帳號存在"
    
    # 檢查 IAM 角色
    echo ""
    log_info "目前綁定的角色:"
    gcloud projects get-iam-policy ${PROJECT_ID} \
        --flatten="bindings[].members" \
        --format="table(bindings.role)" \
        --filter="bindings.members:serviceAccount:${SERVICE_ACCOUNT}" 2>/dev/null | grep -v "^ROLE$" | head -10 | while read role; do
        if [[ -n "$role" ]]; then
            echo "   - ${role}"
        fi
    done
    
    # 檢查是否有 vertex AI 相關角色
    VERTEX_ROLES=$(gcloud projects get-iam-policy ${PROJECT_ID} \
        --flatten="bindings[].members" \
        --format="value(bindings.role)" \
        --filter="bindings.members:serviceAccount:${SERVICE_ACCOUNT}" 2>/dev/null | grep "aiplatform" || echo "")
    
    if [[ -n "$VERTEX_ROLES" ]]; then
        log_success "✅ 已具有 Vertex AI 權限"
    else
        log_warn "⚠️  缺少 Vertex AI 專屬角色"
        echo "   建議添加: roles/aiplatform.user"
        echo "   指令: gcloud projects add-iam-policy-binding ${PROJECT_ID} \\"
        echo "     --member=\"serviceAccount:${SERVICE_ACCOUNT}\" \\"
        echo "     --role=\"roles/aiplatform.user\""
    fi
else
    log_error "❌ 服務帳號不存在"
    echo "   檔案路徑: /home/ubuntu/projects/ds/litellm/deploy/litellm/credentials/vertex-ai/prod.json"
    echo "   檢查方式: 確認 JSON 檔案中的 client_email 欄位"
fi

# ═════════════════════════════════════════════════════════════════
log_section "4. Model Garden 存取測試"
# ═════════════════════════════════════════════════════════════════

log_info "嘗試呼叫 Vertex AI API..."

# 使用服務帳號測試
if [[ -f "/home/ubuntu/projects/ds/litellm/deploy/litellm/credentials/vertex-ai/prod.json" ]]; then
    export GOOGLE_APPLICATION_CREDENTIALS=/home/ubuntu/projects/ds/litellm/deploy/litellm/credentials/vertex-ai/prod.json
    
    # 嘗試列出模型
    MODELS=$(gcloud ai models list --region=asia-east1 --format="value(displayName)" 2>/dev/null | head -5 || echo "")
    
    if [[ -n "$MODELS" ]]; then
        log_success "✅ 可以存取 Model Garden"
        echo "   可用模型:"
        echo "$MODELS" | while read model; do
            echo "     - ${model}"
        done
    else
        log_error "❌ 無法存取 Model Garden"
        echo "   可能原因:"
        echo "     1. 專案未開通生成式 AI 服務"
        echo "     2. 組織政策限制"
        echo "     3. 需要申請特定模型權限"
        echo ""
        echo "   檢查網址:"
        echo "     https://console.cloud.google.com/vertex-ai/model-garden?project=${PROJECT_ID}"
    fi
else
    log_warn "⚠️  找不到 credential 檔案，跳過 API 測試"
fi

# ═════════════════════════════════════════════════════════════════
log_section "5. 配額限制檢查"
# ═════════════════════════════════════════════════════════════════

log_info "Vertex AI 配額狀態:"
gcloud ai quotas list --region=asia-east1 --format="table(metric,limit)" 2>/dev/null | head -10 || log_warn "無法取得配額資訊（需要更多權限）"

# ═════════════════════════════════════════════════════════════════
log_section "總結"
# ═════════════════════════════════════════════════════════════════

echo ""
echo -e "${BOLD}檢查完成！${NC}"
echo ""
echo -e "${YELLOW}如果上方有 ❌，請依序處理：${NC}"
echo "1. 先綁定計費帳號（最重要）"
echo "2. 啟用 Vertex AI API"
echo "3. 添加服務帳號 IAM 角色"
echo "4. 在 Model Garden 頁面啟用模型"
echo ""
echo -e "${BLUE}需要管理員協助的項目：${NC}"
echo "- 計費帳號綁定"
echo "- 組織政策調整"
echo "- Model Garden 存取權申請"
echo ""
