#!/bin/bash
# =============================================================================
# A2A 遷移前備份腳本
# =============================================================================
# 用途：在執行 A2A migration 前，將目前所有受影響檔案的狀態儲存為 git
#       branch。若遷移後需要退版，可一鍵回復。
#
# 使用方式：
#   ./scripts/backup.sh              # 建立備份
#   ./scripts/rollback.sh            # 從備份還原
#
# 注意：
#   - 此腳本會建立 git branch backup/a2a-pre-migration
#   - 如果該 branch 已存在，會被強制覆蓋
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
log_warn()    { echo -e "${YELLOW}⚠${NC} $1"; }
log_error()   { echo -e "${RED}✗${NC} $1" >&2; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

cd "$REPO_ROOT"

if ! git rev-parse --git-dir &>/dev/null; then
    log_error "這不是一個 git repository"
    exit 1
fi

BRANCH_NAME="backup/a2a-pre-migration"

echo ""
echo -e "${BOLD}${BLUE}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${BLUE}║${NC}     A2A 遷移前備份                              ${BOLD}${BLUE}║${NC}"
echo -e "${BOLD}${BLUE}╚══════════════════════════════════════════════════╝${NC}"
echo ""

CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
log_info "目前分支: ${CURRENT_BRANCH}"

FILES=(
    ".opencode/"
    "opencode.json"
    "opencode.json.template"
)

if ! git diff --quiet -- "${FILES[@]}" 2>/dev/null; then
    log_info "偵測到未提交的變更，正在儲存到 stash..."
    STASH_NAME="a2a-backup-$(date +%Y%m%d-%H%M%S)"
    if git stash push -- "${FILES[@]}" -m "$STASH_NAME" 2>/dev/null; then
        git stash branch "$BRANCH_NAME" 2>/dev/null || true
        log_success "備份 branch 已建立: ${BRANCH_NAME}"
        git checkout "$CURRENT_BRANCH" 2>/dev/null
        git stash pop 2>/dev/null || true
    else
        log_warn "stash 為空（無變更）或發生錯誤"
    fi
else
    log_info "受影響檔案無未提交變更，建立備份標記..."
    git branch -f "$BRANCH_NAME" HEAD 2>/dev/null
    log_success "備份 branch 已建立: ${BRANCH_NAME}（指向當前 HEAD）"
fi

echo ""
echo -e "${BOLD}📋 備份摘要${NC}"
echo -e "  備份名稱:  ${BRANCH_NAME}"
echo -e "  備份時間:  $(date '+%Y-%m-%d %H:%M:%S')"
echo -e "  原始分支:  ${CURRENT_BRANCH}"
echo ""
echo -e "${BOLD}🔄 退版方式${NC}"
echo -e "  ${GREEN}一鍵還原:${NC}  ./scripts/rollback.sh"
echo -e "  ${GREEN}手動還原:${NC}  git checkout ${BRANCH_NAME} -- ${FILES[*]}"
echo -e "  ${GREEN}查看差異:${NC}  git diff ${BRANCH_NAME} -- ${FILES[*]}"
echo ""
