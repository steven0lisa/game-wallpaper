#!/bin/bash
# Builds the release binary and packages Heroes3Wallpaper.app
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release

APP="build/Heroes3Wallpaper.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Heroes3Wallpaper "$APP/Contents/MacOS/Heroes3Wallpaper"
# 内置地图：从 VCMI 地图目录（或 base.apk 解包目录）挑选 20 张体积最大的（相近名去重）
python3 scripts/pick_maps.py "$APP/Contents/Resources" 20 \
    "$HOME/Library/Application Support/vcmi/Maps" \
    base.apk_assets_maps || cp base.apk_assets_maps/*.h3m "$APP/Contents/Resources/" 2>/dev/null || true

# Web 地图查看器资源
mkdir -p "$APP/Contents/Resources/webviewer"
cp web/public/index.html web/public/viewer.js "$APP/Contents/Resources/webviewer/"

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
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
PLIST

echo "Packaged $APP"
