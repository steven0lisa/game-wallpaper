#!/bin/bash
# Build the Android APK: decrypt bundled maps -> bake scenes.bin + atlases -> gradle.
#
#   ./scripts/build_android.sh            # debug apk (local dev)
#   ./scripts/build_android.sh release    # release apk (signed if keystore props given)
#
# Scene assets are plaintext on disk only (gitignored); the repo holds the
# encrypted .h3m copies and the baker consumes the local vcmi H3sprite.lod.
# CI runs this same script with BUNDLED_MAPS_PASS + H3_LOD provided.
set -euo pipefail
cd "$(dirname "$0")/.."

MODE="${1:-debug}"
# AGP 8.x needs JDK 17; dev machine default may be 11 (CI sets up Java via setup-java)
if [ -z "${JAVA_HOME:-}" ] || [ -x "/Library/Java/JavaVirtualMachines/jdk-17.jdk/Contents/Home/bin/java" ]; then
    export JAVA_HOME="/Library/Java/JavaVirtualMachines/jdk-17.jdk/Contents/Home"
    export PATH="$JAVA_HOME/bin:$PATH"
fi
GRADLE="${GRADLE:-$HOME/tools/gradle-8.7/bin/gradle}"
[ -x "$GRADLE" ] || GRADLE=gradle

# ---- 1. decrypt the 3 bundled maps to a temp dir ----
MAP_DIR="${MAP_DIR:-/tmp/h3wallpaper-maps}"
if [ ! -f "$MAP_DIR/Back For Revenge.h3m" ]; then
    echo "[android] decrypting bundled maps -> $MAP_DIR"
    BUNDLED_MAPS_PASS="${BUNDLED_MAPS_PASS:-}" ./scripts/bundle_maps.sh decrypt "$MAP_DIR"
fi

# ---- 2. bake scenes.bin + atlas PNGs ----
OUT="android/app/src/main/assets/scenes"
if [ "${SKIP_BAKE:-0}" != "1" ]; then
    echo "[android] baking scenes -> $OUT"
    node android/bake/bake.js --list scripts/bundled_maps.txt --map-dir "$MAP_DIR" --out "$OUT"
else
    echo "[android] SKIP_BAKE=1, using existing assets in $OUT"
fi

# ---- 3. gradle build ----
PROPS=()
if [ -n "${RELEASE_STORE_FILE:-}" ]; then
    PROPS+=("-PRELEASE_STORE_FILE=$RELEASE_STORE_FILE"
            "-PRELEASE_STORE_PASSWORD=$RELEASE_STORE_PASSWORD"
            "-PRELEASE_KEY_ALIAS=$RELEASE_KEY_ALIAS"
            "-PRELEASE_KEY_PASSWORD=$RELEASE_KEY_PASSWORD")
fi
echo "[android] gradle assemble$MODE"
# bash 3.2 (macOS) has no ${var^}; capitalize explicitly
TASK="assemble$(printf '%s' "$MODE" | awk '{print toupper(substr($0,1,1)) substr($0,2)}')"
# macOS bash 3.2: empty array + set -u = unbound variable; expand conditionally
( cd android && "$GRADLE" --no-daemon -q "$TASK" ${PROPS[@]+"${PROPS[@]}"} )

APK="android/app/build/outputs/apk/$MODE/app-$MODE.apk"
[ -f "$APK" ] || { echo "ERROR: $APK not produced" >&2; exit 1; }
mkdir -p build
cp "$APK" "build/GameWallpaper.apk"
echo "[android] OK: build/GameWallpaper.apk ($(du -h build/GameWallpaper.apk | cut -f1))"
