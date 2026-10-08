#!/bin/bash
# 生成 release notes：从上个 tag（或仓库起点）到指定 tag 的 commit，按 feat/fix/other 分组。
# 用法: scripts/gen_release_notes.sh v1.0
set -euo pipefail
TAG="${1:?usage: gen_release_notes.sh <tag>}"
PREV="$(git describe --tags --abbrev=0 "${TAG}^" 2>/dev/null || true)"
RANGE="${PREV:+$PREV..}$TAG"

echo "## GameWallpaper $TAG"
echo
if [ -n "$PREV" ]; then
    echo "Changes since $PREV:"
else
    echo "First release."
fi
echo

log() { git log --no-merges --pretty=format:'- %s' "$RANGE" 2>/dev/null || true; }

echo "### ✨ Features"
log | grep -E '^- (feat|add|support)' || echo "- (none)"
echo
echo "### 🐛 Fixes"
log | grep -E '^- fix' || echo "- (none)"
echo
echo "### 📦 Other"
log | grep -vE '^- (feat|add|support|fix)' || echo "- (none)"
echo
echo "---"
echo "ℹ️ 发布的 dmg 为 **lite 版**：不含任何原版游戏资源（版权资产不入库）。"
echo "首次运行后在菜单栏指定游戏数据目录（如 VCMI 的目录）与地图目录即可。"
echo "未签名构建：若被 Gatekeeper 拦截，右键 → Open，或 \`xattr -d com.apple.quarantine /Applications/GameWallpaper.app\`。"
if [ -n "$PREV" ]; then
    echo
    echo "**Full changelog**: https://github.com/${GITHUB_REPOSITORY:-steven0lisa/game-wallpaper}/compare/$PREV...$TAG"
fi
