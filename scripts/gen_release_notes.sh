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
echo "ℹ️ dmg 内置 3 张 XL 大地图（未指定地图目录时自动加载）；精灵资源"
echo "（H3sprite.lod，需自备原版游戏文件）不入库——首次运行请在菜单栏"
echo "「Choose Data Folder…」指定游戏数据目录（如 VCMI 的目录）。"
echo "未签名构建：若被 Gatekeeper 拦截，右键 → Open，或 \`xattr -d com.apple.quarantine /Applications/GameWallpaper.app\`。"
if [ -n "$PREV" ]; then
    echo
    echo "**Full changelog**: https://github.com/${GITHUB_REPOSITORY:-steven0lisa/game-wallpaper}/compare/$PREV...$TAG"
fi
