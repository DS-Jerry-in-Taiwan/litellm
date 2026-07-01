#!/bin/bash
# =============================================================================
# LiteLLM Docker Compose 自動部署腳本
# =============================================================================
# 用途：一鍵部署 LiteLLM 服務堆疊
# 功能：
#   1. 檢查必要檔案 (.env, config.yaml)
#   2. 自動生成隨機密鑰（若 .env 不存在）
#   3. 驗證 API Key 配置
#   4. 啟動 Docker Compose 服務
#   5. 等待服務就緒並顯示狀態
# =============================================================================

set -euo pipefail

# ─────────────────────────────────────────────────────────────
# 顏色定義
# ─────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log_info() { echo -e "${BLUE}ℹ${NC} $1"; }
log_success() { echo -e "${GREEN}✓${NC} $1"; }
log_warn() { echo -e "${YELLOW}⚠${NC} $1"; }
log_error() { echo -e "${RED}✗${NC} $1" >&2; }
log_section() { echo -e "\n${BOLD}${CYAN}▶ $1${NC}"; }

# ─────────────────────────────────────────────────────────────
# 檢查 Docker
# ─────────────────────────────────────────────────────────────
check_docker() {
    log_section "檢查 Docker 環境"
    
    if ! command -v docker &> /dev/null; then
        log_error "Docker 未安裝"
        exit 1
    fi
    
    if ! docker info &> /dev/null; then
        log_error "Docker daemon 未運行，請先啟動 Docker"
        exit 1
    fi
    
    if ! command -v docker-compose &> /dev/null && ! docker compose version &> /dev/null; then
        log_error "Docker Compose 未安裝"
        exit 1
    fi
    
    log_success "Docker 環境檢查通過"
}

# ─────────────────────────────────────────────────────────────
# 生成隨機密鑰
# ─────────────────────────────────────────────────────────────
generate_secrets() {
    log_section "生成隨機密鑰"
    
    local master_key="sk-$(openssl rand -hex 32)"
    local salt_key="$(openssl rand -hex 32)"
    local postgres_pass="$(openssl rand -base64 24 | tr -d '=+/' | cut -c1-24)"
    local database_url="postgresql://litellm:${postgres_pass}@postgres:5432/litellm"
    
    # 輸出到檔案
    cat > .env << EOF
# =============================================================================
# LiteLLM .env — 自動生成
# 生成時間: $(date '+%Y-%m-%d %H:%M:%S')
# 警告: 此檔案包含敏感資訊，請勿 commit 進 Git
# =============================================================================

# === LiteLLM Core Secrets ===
LITELLM_MASTER_KEY=${master_key}
LITELLM_SALT_KEY=${salt_key}

# === PostgreSQL Database ===
DATABASE_URL=${database_url}
POSTGRES_DB=litellm
POSTGRES_USER=litellm
POSTGRES_PASSWORD=${postgres_pass}

# === LLM Provider API Keys (請手動填入) ===
# OpenAI
OPENAI_API_KEY=replace-with-provider-key

# Anthropic (可選)
# ANTHROPIC_API_KEY=replace-with-anthropic-key

# Azure OpenAI (可選)
# AZURE_API_KEY=replace-with-azure-key
# AZURE_API_BASE=https://your-resource.openai.azure.com
# AZURE_API_VERSION=2024-06-01

# === Redis ===
REDIS_HOST=redis
REDIS_PORT=6379

# === LiteLLM General Settings ===
STORE_MODEL_IN_DB=True
EOF
    
    chmod 600 .env
    log_success ".env 已建立並設定權限 600"
    log_warn "請編輯 .env 填入 LLM Provider API Key"
}

# ─────────────────────────────────────────────────────────────
# 檢查 .env 檔案
# ─────────────────────────────────────────────────────────────
check_env() {
    log_section "檢查環境設定檔"
    
    if [[ ! -f ".env" ]]; then
        log_warn ".env 不存在，從 .env.example 建立..."
        
        if [[ ! -f ".env.example" ]]; then
            log_error ".env.example 也不存在！無法自動建立 .env"
            exit 1
        fi
        
        generate_secrets
    else
        log_success ".env 已存在"
    fi
    
    # 檢查是否仍為 placeholder
    if grep -q "replace-with-provider-key" .env; then
        log_warn "OPENAI_API_KEY 仍為 placeholder"
        log_warn "部署後請透過以下方式之一新增 Model："
        log_warn "  1. 編輯 .env 填入 API Key，然後執行: docker compose restart litellm"
        log_warn "  2. 使用 Admin UI: http://localhost:4000/ui"
    fi
    
    # 檢查權限
    local perms
    perms=$(stat -c "%a" .env)
    if [[ "$perms" != "600" ]]; then
        log_warn ".env 權限為 $perms，建議設定為 600"
        chmod 600 .env
        log_success ".env 權限已更新為 600"
    fi
}

# ─────────────────────────────────────────────────────────────
# 檢查 config.yaml
# ─────────────────────────────────────────────────────────────
check_config() {
    log_section "檢查 LiteLLM 設定檔"
    
    if [[ ! -f "config.yaml" ]]; then
        log_warn "config.yaml 不存在，從範本建立..."
        
        if [[ -f "config.yaml.example" ]]; then
            cp config.yaml.example config.yaml
            log_success "config.yaml 已從範本複製"
        else
            log_error "config.yaml.example 不存在！"
            exit 1
        fi
    else
        log_success "config.yaml 已存在"
    fi
}

# ─────────────────────────────────────────────────────────────
# 顯示當前配置摘要
# ─────────────────────────────────────────────────────────────
show_config_summary() {
    log_section "配置摘要"
    
    echo -e "${BOLD}服務:${NC}"
    echo "  - LiteLLM Proxy: http://localhost:4000"
    echo "  - Admin UI:      http://localhost:4000/ui"
    echo "  - Prometheus:    http://localhost:9091 (如啟用)"
    echo ""
    echo -e "${BOLD}容器:${NC}"
    echo "  - litellm-proxy"
    echo "  - litellm-postgres"
    echo "  - litellm-redis"
    echo "  - litellm-prometheus (可選)"
    echo ""
    echo -e "${BOLD}資料卷:${NC}"
    echo "  - postgres_data"
    echo "  - prometheus_data"
}

# ─────────────────────────────────────────────────────────────
# 部署服務
# ─────────────────────────────────────────────────────────────
deploy() {
    log_section "啟動 Docker Compose 服務"
    
    # 拉取最新 image
    log_info "拉取 Docker images..."
    docker-compose pull
    
    # 啟動服務
    log_info "啟動服務..."
    docker-compose up -d
    
    log_success "服務已啟動"
}

# ─────────────────────────────────────────────────────────────
# 等待服務就緒
# ─────────────────────────────────────────────────────────────
wait_for_healthy() {
    log_section "等待服務就緒"
    
    local services=("litellm-postgres" "litellm-redis" "litellm-proxy")
    local max_wait=120
    local waited=0
    
    for service in "${services[@]}"; do
        log_info "等待 $service..."
        
        while [[ $waited -lt $max_wait ]]; do
            local status
            status=$(docker inspect --format='{{.State.Health.Status}}' "$service" 2>/dev/null || echo "unknown")
            
            if [[ "$status" == "healthy" ]]; then
                log_success "$service 已就緒"
                break
            elif [[ "$status" == "unhealthy" ]]; then
                log_error "$service 健康檢查失敗"
                docker logs "$service" --tail 20
                exit 1
            fi
            
            sleep 2
            ((waited+=2))
            echo -n "."
        done
        
        if [[ $waited -ge $max_wait ]]; then
            log_error "$service 啟動超時"
            exit 1
        fi
    done
    
    echo ""
    log_success "所有服務已就緒"
}

# ─────────────────────────────────────────────────────────────
# 顯示部署後資訊
# ─────────────────────────────────────────────────────────────
show_post_deploy_info() {
    log_section "部署完成"
    
    echo -e "${GREEN}${BOLD}✅ LiteLLM 已成功部署！${NC}"
    echo ""
    echo -e "${BOLD}🌐 存取端點:${NC}"
    echo "  LiteLLM API:   http://localhost:4000"
    echo "  Admin UI:      http://localhost:4000/ui"
    echo "  Health Check:  http://localhost:4000/health/liveliness"
    echo ""
    echo -e "${BOLD}📊 管理指令:${NC}"
    echo "  查看日誌:      docker-compose logs -f litellm"
    echo "  停止服務:      docker-compose down"
    echo "  重新啟動:      docker-compose restart"
    echo ""
    echo -e "${BOLD}🔑 首次使用:${NC}"
    
    # 取得 master key
    local master_key
    master_key=$(grep "LITELLM_MASTER_KEY=" .env | cut -d'=' -f2)
    echo "  Master Key:    ${master_key:0:20}..."
    echo ""
    echo -e "${YELLOW}⚠️ 請記下此 Master Key，用於 Admin API 認證${NC}"
    echo ""
    
    # 檢查是否有 placeholder
    if grep -q "replace-with-provider-key" .env; then
        echo -e "${YELLOW}${BOLD}⚠️ 注意: 尚未設定 LLM Provider API Key${NC}"
        echo "  請執行以下步驟啟用模型："
        echo "    1. 編輯 .env 填入 OPENAI_API_KEY 或其他 provider key"
        echo "    2. 執行: docker-compose restart litellm"
        echo "    3. 或透過 Admin UI (http://localhost:4000/ui) 動態新增模型"
    fi
}

# ─────────────────────────────────────────────────────────────
# 主程式
# ─────────────────────────────────────────────────────────────
main() {
    echo -e "${BOLD}${CYAN}"
    echo "╔════════════════════════════════════════════════════╗"
    echo "║     LiteLLM Docker Compose 部署腳本              ║"
    echo "╚════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    
    # 切換到腳本所在目錄
    cd "$(dirname "$0")"
    
    check_docker
    check_env
    check_config
    show_config_summary
    
    # 確認部署
    echo ""
    read -r -p "確認部署? [Y/n]: " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]] && [[ -n "$confirm" ]]; then
        log_info "已取消部署"
        exit 0
    fi
    
    deploy
    wait_for_healthy
    show_post_deploy_info
}

# 執行主程式
main "$@"
