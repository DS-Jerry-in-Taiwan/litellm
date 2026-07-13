#!/bin/bash
# =============================================================================
# LiteLLM 服務狀態檢查腳本
# =============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

echo -e "${BOLD}${BLUE}LiteLLM 服務狀態${NC}\n"

# 檢查容器狀態
echo -e "${BOLD}容器狀態:${NC}"
docker-compose ps --format 'table {{.Name}}\t{{.Service}}\t{{.Status}}\t{{.Ports}}' 2>/dev/null || \
docker compose ps --format 'table {{.Name}}\t{{.Service}}\t{{.Status}}\t{{.Ports}}' 2>/dev/null || \
docker ps --filter "name=litellm" --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}'

echo ""
echo -e "${BOLD}健康檢查:${NC}"

# 檢查 LiteLLM 健康端點
if curl -s http://localhost:4000/health/liveliness > /dev/null 2>&1; then
    echo -e "  ${GREEN}✓${NC} LiteLLM API (http://localhost:4000)"
else
    echo -e "  ${RED}✗${NC} LiteLLM API 無回應"
fi

# 檢查 Admin UI
if curl -s http://localhost:4000/ui > /dev/null 2>&1; then
    echo -e "  ${GREEN}✓${NC} Admin UI (http://localhost:4000/ui)"
else
    echo -e "  ${YELLOW}⚠${NC} Admin UI 可能尚未就緒"
fi

echo ""
echo -e "${BOLD}最近日誌:${NC}"
docker-compose logs --tail 5 litellm 2>/dev/null || \
docker compose logs --tail 5 litellm 2>/dev/null || \
echo "  無法取得日誌"
