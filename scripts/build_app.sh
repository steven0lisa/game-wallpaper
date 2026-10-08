#!/bin/bash
# Builds the release binary for both arm64 and x86_64, merges into a universal
# (fat) binary via lipo, and packages GameWallpaper.app / .dmg
#
# Asset modes:
#   REQUIRE_ASSETS=1 (default, local dev) — bundles H3sprite.lod + maps + About
#     assets; missing assets abort the build, never a silent empty package.
#   REQUIRE_ASSETS=0 (CI/release) — no copyrighted assets bundled; users pick the
#     data dir / maps dir in the menu at runtime (assets never enter the repo,
#     see .gitignore). Bundled XL maps are still decrypted via BUNDLED_MAPS_PASS.
#
# Versioning: derived from git by default — MARKETING_VERSION = latest tag
# (without the v prefix), BUILD_NUMBER = <commit count>.<short sha>;
# overridable via environment variables.
set -euo pipefail
cd "$(dirname "$0")/.."

REQUIRE_ASSETS="${REQUIRE_ASSETS:-1}"

echo "==> Building arm64..."
swift build -c release --arch arm64
echo "==> Building x86_64..."
swift build -c release --arch x86_64

# Per-architecture binaries
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

# Bundles the render-required H3sprite.lod (all terrain/object sprites, ~65MB)
# — the prerequisite for self-contained distribution. Runtime resolution order
# (AppDelegate.dataDir / Heroes3Engine.defaultDataDir):
#   user-set dataDir > bundle Resources/Data/H3sprite.lod > ~/Library/Application Support/vcmi
LOD="${LOD:-$HOME/Library/Application Support/vcmi/Data/H3sprite.lod}"
if [ -f "$LOD" ]; then
    mkdir -p "$APP/Contents/Resources/Data"
    cp "$LOD" "$APP/Contents/Resources/Data/H3sprite.lod"
elif [ "$REQUIRE_ASSETS" = "1" ]; then
    echo "ERROR: no H3sprite.lod at $LOD — required asset missing, aborting (set REQUIRE_ASSETS=0 for a sprite-free CI build)" >&2
    exit 1
else
    echo "WARN: REQUIRE_ASSETS=0 — packaging without sprite assets; users pick the data dir at runtime" >&2
fi

# Bundled XL maps: the fixed list in scripts/bundled_maps.txt.
# Source priority: plain text from local MAP_SRC > decrypt the in-repo encrypted
# copy (needs BUNDLED_MAPS_PASS; CI gets it from a GitHub secret).
# If neither is available: REQUIRE_ASSETS=1 aborts; =0 warns and ships mapless.
MAP_SRC="${MAP_SRC:-$HOME/Library/Application Support/vcmi/Maps}"
BUNDLED_MISSING=0
while IFS= read -r name; do
    [ -z "$name" ] && continue
    case "$name" in \#*) continue ;; esac
    if [ -f "$MAP_SRC/$name" ]; then
        cp "$MAP_SRC/$name" "$APP/Contents/Resources/"
    elif [ -f "Resources/BundledMaps/$name.enc" ] && [ -n "${BUNDLED_MAPS_PASS:-}" ]; then
        openssl enc -d -aes-256-cbc -pbkdf2 -in "Resources/BundledMaps/$name.enc" \
            -out "$APP/Contents/Resources/$name" -pass env:BUNDLED_MAPS_PASS
    else
        echo "WARN: bundled map unavailable: $name (not in $MAP_SRC and no encrypted copy/password)" >&2
        BUNDLED_MISSING=$((BUNDLED_MISSING + 1))
    fi
done < scripts/bundled_maps.txt
if [ "$REQUIRE_ASSETS" = "1" ]; then
    [ "$BUNDLED_MISSING" = "0" ] || { echo "ERROR: $BUNDLED_MISSING bundled map(s) missing, aborting (configure the BUNDLED_MAPS_PASS secret for CI)" >&2; exit 1; }
fi

# Web map viewer resources
mkdir -p "$APP/Contents/Resources/webviewer"
cp web/public/index.html web/public/viewer.js "$APP/Contents/Resources/webviewer/"

# About-window assets (Heroes-3 style): angel logo animation + DIALGBOX border
# + IOKAY32 button, exported to PNG from H3sprite.lod/H3bitmap.lod so the About
# window renders on any machine.
if [ -f "$LOD" ]; then
    mkdir -p "$APP/Contents/Resources/about"
    python3 scripts/export_about_assets.py "$LOD" "$APP/Contents/Resources/about"
else
    echo "WARN: no H3sprite.lod — About window falls back to plain text style"
fi

# i18n localization (en / zh-Hans, follows the system language)
for lproj in en zh-Hans; do
    mkdir -p "$APP/Contents/Resources/$lproj.lproj"
    cp "Resources/$lproj.lproj/Localizable.strings" "$APP/Contents/Resources/$lproj.lproj/" 2>/dev/null || true
done

# Version: tag v{major}.{minor} -> CFBundleShortVersionString; build number = <commit count>.<sha>
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

# Minimal resources Finder/LaunchServices expect (version.plist with the real build number)
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
# PkgInfo — older launchservices look for it
with open(os.path.join(app, "Contents", "PkgInfo"), "w") as f:
    f.write("APPL????")
PY

# Unsigned builds may be blocked by Gatekeeper; drop quarantine for local testing
xattr -d com.apple.quarantine "$APP" 2>/dev/null || true

echo "==> Packaging ${APP%.app}.dmg ..."
DMG="build/GameWallpaper.dmg"
rm -f "$DMG"
hdiutil create -volname "GameWallpaper" -srcfolder "$APP" -ov -format UDZO "$DMG" >/dev/null

echo "Packaged $APP"
echo "Dmg     $DMG"
