#!/bin/bash
# Builds the release binary for both arm64 and x86_64, merges into a universal
# (fat) binary via lipo, and packages GameWallpaper.app / .dmg
#
# 资源模式：
#   REQUIRE_ASSETS=1（默认，本机开发）—— 内置 H3sprite.lod + 地图 + About 资源，
#     缺资源直接失败，不允许静默出空包；
#   REQUIRE_ASSETS=0（CI/发布 lite 版）—— 不内置任何版权资源，运行时用户在菜单里
#     指定数据目录/地图目录（版权资源永不入库，见 .gitignore）。
#
# 版本号：默认从 git 推导——MARKETING_VERSION = 最新 tag（v 前缀去掉），
# BUILD_NUMBER = <commit 数>.<short sha>；可用环境变量覆盖。
set -euo pipefail
cd "$(dirname "$0")/.."

REQUIRE_ASSETS="${REQUIRE_ASSETS:-1}"

echo "==> Building arm64..."
swift build -c release --arch arm64
echo "==> Building x86_64..."
swift build -c release --arch x86_64

# 两个架构各自产物
ARM64_BIN=".build/arm64-apple-macosx/release/GameWallpaper"
X86_BIN=".build/x86_64-apple-macosx/release/GameWallpaper"
[ -f "$ARM64_BIN" ] || { echo "missing $ARM64_BIN" >&2; exit 1; }
[ -f "$X86_BIN" ] || { echo "missing $X86_BIN" >&2; exit 1; }

LIPO="$(xcrun --find lipo)"

APP="build/GameWallpaper.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "==> Merging into universal binary..."
"$LIPO" -create "$ARM64_BIN" "$X86_BIN" -output "$APP/Contents/MacOS/GameWallpaper"
file "$APP/Contents/MacOS/GameWallpaper"
"$LIPO" -info "$APP/Contents/MacOS/GameWallpaper"

# 内置渲染必需的 H3sprite.lod（地形/物件全部精灵，~65MB）——自包含分发的前提。
# 运行时解析顺序见 AppDelegate.dataDir / Heroes3Engine.defaultDataDir：
#   用户设置 dataDir > bundle Resources/Data/H3sprite.lod > ~/Library/Application Support/vcmi
LOD="${LOD:-$HOME/Library/Application Support/vcmi/Data/H3sprite.lod}"
if [ -f "$LOD" ]; then
    mkdir -p "$APP/Contents/Resources/Data"
    cp "$LOD" "$APP/Contents/Resources/Data/H3sprite.lod"
elif [ "$REQUIRE_ASSETS" = "1" ]; then
    echo "ERROR: no H3sprite.lod at $LOD —— 渲染必需资源缺失，拒绝打包（CI lite 版请设 REQUIRE_ASSETS=0）" >&2
    exit 1
else
    echo "WARN: REQUIRE_ASSETS=0 —— 打包无资源 lite 版，运行时需用户指定数据目录" >&2
fi

# 内置地图：从 VCMI 地图目录拷贝 .h3m（相近名去重，总量截到 ~80MB 保证 dmg 合理）
MAP_SRC="${MAP_SRC:-$HOME/Library/Application Support/vcmi/Maps}"
if [ -d "$MAP_SRC" ]; then
    LIMIT=83886080
    [ "$REQUIRE_ASSETS" = "1" ] || LIMIT=20971520   # lite 版只带 20MB 示例地图
    python3 scripts/pick_maps.py "$APP/Contents/Resources" "$LIMIT" "$MAP_SRC"
fi
if [ "$REQUIRE_ASSETS" = "1" ] && [ -z "$(ls "$APP/Contents/Resources"/*.h3m 2>/dev/null)" ]; then
    echo "ERROR: no .h3m collected —— 地图资源缺失，拒绝打包（CI lite 版请设 REQUIRE_ASSETS=0）" >&2
    exit 1
fi

# Web 地图查看器资源
mkdir -p "$APP/Contents/Resources/webviewer"
cp web/public/index.html web/public/viewer.js "$APP/Contents/Resources/webviewer/"

# About 窗口资源（英雄无敌3 风格）：天使 Logo 动画 + DIALGBOX 边框 + IOKAY32 按钮。
# 从 H3sprite.lod/H3bitmap.lod 导出 PNG，打包进 app，使 About 在任何机器都能显示。
if [ -f "$LOD" ]; then
    mkdir -p "$APP/Contents/Resources/about"
    python3 scripts/export_about_assets.py "$LOD" "$APP/Contents/Resources/about"
else
    echo "WARN: no H3sprite.lod, About 窗口将退化为纯文本样式"
fi

# i18n 本地化（跟随系统语言中/英）
for lproj in en zh-Hans; do
    mkdir -p "$APP/Contents/Resources/$lproj.lproj"
    cp "Resources/$lproj.lproj/Localizable.strings" "$APP/Contents/Resources/$lproj.lproj/" 2>/dev/null || true
done

# 版本号：tag v{major}.{minor} → CFBundleShortVersionString；构建号 = <commit 数>.<sha>
if [ -z "${MARKETING_VERSION:-}" ]; then
    TAG="$(git describe --tags --abbrev=0 2>/dev/null || true)"
    MARKETING_VERSION="${TAG#v}"
    [ -n "$MARKETING_VERSION" ] || MARKETING_VERSION="0.1"
fi
if [ -z "${BUILD_NUMBER:-}" ]; then
    if git rev-parse HEAD >/dev/null 2>&1; then
        BUILD_NUMBER="$(git rev-list --count HEAD).$(git rev-parse --short HEAD)"
    else
        BUILD_NUMBER="$(date +%Y%m%d%H%M)"
    fi
fi
echo "==> Version $MARKETING_VERSION build $BUILD_NUMBER (REQUIRE_ASSETS=$REQUIRE_ASSETS)"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>GameWallpaper</string>
    <key>CFBundleIdentifier</key>
    <string>personal.steven.gamewallpaper</string>
    <key>CFBundleName</key>
    <string>GameWallpaper</string>
    <key>CFBundleDisplayName</key>
    <string>Game Wallpaper</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$MARKETING_VERSION</string>
    <key>CFBundleVersion</key>
    <string>$BUILD_NUMBER</string>
    <key>CFBundleLocalizations</key>
    <array>
        <string>en</string>
        <string>zh-Hans</string>
    </array>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright © 2026 steven0lisa</string>
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

# 补齐 Finder/LaunchServices 需要的最小资源（version.plist 用真实 build 号）
python3 - "$APP" "$MARKETING_VERSION" "$BUILD_NUMBER" <<'PY'
import os, plistlib, sys
app, mark, build = sys.argv[1], sys.argv[2], sys.argv[3]
ver = {
    "BuildVersion": build,
    "CFBundleShortVersionString": mark,
    "CFBundleVersion": build,
}
with open(os.path.join(app, "Contents", "version.plist"), "wb") as f:
    plistlib.dump(ver, f)
# 创建 PkgInfo —— 老一代 launchservices 会看它
with open(os.path.join(app, "Contents", "PkgInfo"), "w") as f:
    f.write("APPL????")
PY

# 仅本地运行在 arm64 或 x86_64 上时可能被 Gatekeeper 拦截（未签名），本地测试用 xattr 放行
xattr -d com.apple.quarantine "$APP" 2>/dev/null || true

echo "==> Packaging ${APP%.app}.dmg ..."
DMG="build/GameWallpaper.dmg"
rm -f "$DMG"
hdiutil create -volname "GameWallpaper" -srcfolder "$APP" -ov -format UDZO "$DMG" >/dev/null

echo "Packaged $APP"
echo "Dmg     $DMG"
