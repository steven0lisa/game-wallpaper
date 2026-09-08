#!/bin/bash
# Builds the release binary for both arm64 and x86_64, merges into a universal
# (fat) binary via lipo, and packages Heroes3Wallpaper.app / .dmg
set -euo pipefail
cd "$(dirname "$0")/.."

echo "==> Building arm64..."
swift build -c release --arch arm64
echo "==> Building x86_64..."
swift build -c release --arch x86_64

# 两个架构各自产物
ARM64_BIN=".build/arm64-apple-macosx/release/Heroes3Wallpaper"
X86_BIN=".build/x86_64-apple-macosx/release/Heroes3Wallpaper"
[ -f "$ARM64_BIN" ] || { echo "missing $ARM64_BIN" >&2; exit 1; }
[ -f "$X86_BIN" ] || { echo "missing $X86_BIN" >&2; exit 1; }

LIPO="$(xcrun --find lipo)"

APP="build/Heroes3Wallpaper.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "==> Merging into universal binary..."
"$LIPO" -create "$ARM64_BIN" "$X86_BIN" -output "$APP/Contents/MacOS/Heroes3Wallpaper"
file "$APP/Contents/MacOS/Heroes3Wallpaper"
"$LIPO" -info "$APP/Contents/MacOS/Heroes3Wallpaper"

# 内置地图：从 VCMI 地图目录（或 base.apk 解包目录）挑选 20 张体积最大的（相近名去重）
python3 scripts/pick_maps.py "$APP/Contents/Resources" 20 \
    "$HOME/Library/Application Support/vcmi/Maps" \
    base.apk_assets_maps || cp base.apk_assets_maps/*.h3m "$APP/Contents/Resources/" 2>/dev/null || true

# Web 地图查看器资源
mkdir -p "$APP/Contents/Resources/webviewer"
cp web/public/index.html web/public/viewer.js "$APP/Contents/Resources/webviewer/"

# 补齐 Finder/LaunchServices 需要的最小资源
python3 - "$APP" <<'PY'
import os, plistlib, sys
# version.plist (build 号与 bundle 保持一致)
ver = {
    "BuildVersion": "1",
    "CFBundleShortVersionString": "1.0",
    "CFBundleVersion": "1",
}
with open(os.path.join(sys.argv[1], "Contents", "version.plist"), "wb") as f:
    plistlib.dump(ver, f)
# 创建 PkgInfo —— 老一代 launchservices 会看它
with open(os.path.join(sys.argv[1], "Contents", "PkgInfo"), "w") as f:
    f.write("APPL????")
PY

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>Heroes3Wallpaper</string>
    <key>CFBundleIdentifier</key>
    <string>personal.steven.heroes3wallpaper</string>
    <key>CFBundleName</key>
    <string>Heroes3Wallpaper</string>
    <key>CFBundleDisplayName</key>
    <string>Heroes3 Wallpaper</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
PLIST

# 仅本地运行在 arm64 或 x86_64 上时可能被 Gatekeeper 拦截（未签名），本地测试用 xattr 放行
xattr -d com.apple.quarantine "$APP" 2>/dev/null || true

echo "==> Packaging ${APP%.app}.dmg ..."
DMG="build/Heroes3Wallpaper.dmg"
rm -f "$DMG"
hdiutil create -volname "Heroes3Wallpaper" -srcfolder "$APP" -ov -format UDZO "$DMG" >/dev/null

echo "Packaged $APP"
echo "Dmg     $DMG"
