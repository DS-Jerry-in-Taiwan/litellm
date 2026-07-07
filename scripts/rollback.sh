#!/bin/bash
# =============================================================================
# A2A 遷移還原腳本
# =============================================================================
# 用途：從 backup/a2a-pre-migration branch 回復受影響的檔案。
#       等同於一鍵退版，還原到執行 ./scripts/backup.sh 時的狀態。
#
# 使用方式：
#   ./scripts/rollback.sh
#
# 注意：
#   - 腳本執行後會還原 .opencode/ 等檔案
#   - 還原後請重新啟動 OpenCode session
#   - 不會刪除備份 branch，可再次還原
# =============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

log_info()    { echo -e "${BLUE}ℹ${NC} $1"; }
log_success() { echo -e "${GREEN}✓${NC} $1"; }
log_error()   { echo -e "${RED}✗${NC} $1" >&2; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

cd "$REPO_ROOT"

echo ""
echo -e "${BOLD}${YELLOW}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${YELLOW}║${NC}     A2A 遷移退版還原                            ${BOLD}${YELLOW}║${NC}"
echo -e "${BOLD}${YELLOW}╚══════════════════════════════════════════════════╝${NC}"
echo ""

BRANCH_NAME="backup/a2a-pre-migration"

if ! git rev-parse --verify "$BRANCH_NAME" &>/dev/null; then
    log_error "找不到備份 branch: ${BRANCH_NAME}"
    echo ""
    echo "  可能原因："
    echo "    1. 尚未執行 ./scripts/backup.sh"
    echo "    2. 備份 branch 已被刪除"
    exit 1
fi

FILES=(
    ".opencode/"
    "opencode.json"
    "opencode.json.template"
)

log_info "將從 ${BRANCH_NAME} 還原以下檔案："
for f in "${FILES[@]}"; do
    echo "    ${f}"
done
echo ""

echo -e "${YELLOW}⚠  還原後會覆蓋上述檔案的目前內容。${NC}"
echo -e "    目前工作目錄中的未提交變更（只限上述檔案）將會遺失。"
echo ""
read -r -p "是否繼續？ (y/N) " confirm
if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
    log_info "還原已取消"
    exit 0
fi
echo ""

log_info "正在還原..."
if git checkout "$BRANCH_NAME" -- "${FILES[@]}" 2>/dev/null; then
    log_success "還原完成"
    echo ""
    echo -e "  已還原檔案：${FILES[*]}"
    echo ""
    echo -e "${BOLD}📋 後續步驟${NC}"
    echo -e "  1. 執行差異確認:  git diff --stat"
    echo -e "  2. 重啟 OpenCode 套用設定"
    echo ""
else
    log_error "還原失敗"
    exit 1
fi
