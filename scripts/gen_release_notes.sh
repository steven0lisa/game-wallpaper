#!/bin/bash
# Generates release notes: commits from the previous tag (or repo start) to the
# given tag, grouped as feat/fix/other. Usage: scripts/gen_release_notes.sh v1.0
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
echo "ℹ️ The dmg bundles 3 XL maps (auto-loaded when no maps folder is set). Sprite"
echo "assets (H3sprite.lod, from your original game) are not included — on first"
echo "launch use「Choose Data Folder…」to pick the game data dir (e.g. VCMI's)."
echo "Unsigned build: if Gatekeeper blocks the first launch, right-click -> Open, or \`xattr -d com.apple.quarantine /Applications/GameWallpaper.app\`."
if [ -n "$PREV" ]; then
    echo
    echo "**Full changelog**: https://github.com/${GITHUB_REPOSITORY:-steven0lisa/game-wallpaper}/compare/$PREV...$TAG"
fi
