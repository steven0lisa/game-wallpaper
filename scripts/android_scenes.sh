#!/bin/bash
# Android scene assets: encrypt (dev machine, bakes fresh) / unpack (CI or a
# machine without the game LOD).
#
# The baked bundle (scenes.bin + atlas PNGs) derives from the copyrighted game
# sprites and maps, so like Resources/BundledMaps/*.h3m.enc it only ever exists
# in the repo AES-256 encrypted (password = BUNDLED_MAPS_PASS / PASS_FILE) and
# inside the built APK. Plaintext assets live in android/app/src/main/assets
# (gitignored) and are produced at build time.
#
#   ./scripts/android_scenes.sh encrypt   # bake fresh from LOD + maps -> Resources/AndroidScenes.enc
#   ./scripts/android_scenes.sh unpack    # decrypt into android/app/src/main/assets/scenes
#
# After changing scripts/bundled_maps.txt or the renderer, re-run encrypt and
# commit the new AndroidScenes.enc.
set -euo pipefail
cd "$(dirname "$0")/.."

ENC="Resources/AndroidScenes.enc"
ASSETS="android/app/src/main/assets/scenes"

pass_args() {
    if [ -n "${BUNDLED_MAPS_PASS:-}" ]; then
        echo "-pass" "env:BUNDLED_MAPS_PASS"
    elif [ -f "${PASS_FILE:-$HOME/.config/gamewallpaper/bundled-maps-pass}" ]; then
        echo "-pass" "file:${PASS_FILE:-$HOME/.config/gamewallpaper/bundled-maps-pass}"
    else
        echo "ERROR: no BUNDLED_MAPS_PASS env nor PASS_FILE" >&2
        exit 1
    fi
}

cmd="${1:-}"
case "$cmd" in
encrypt)
    MAP_DIR="${MAP_DIR:-/tmp/h3wallpaper-maps}"
    [ -f "$MAP_DIR/Back For Revenge.h3m" ] || \
        ./scripts/bundle_maps.sh decrypt "$MAP_DIR"
    node android/bake/bake.js --list scripts/bundled_maps.txt \
        --map-dir "$MAP_DIR" --out "$ASSETS"
    mkdir -p Resources
    tar -czf - -C android/app/src/main/assets scenes \
        | openssl enc -aes-256-cbc -pbkdf2 -salt -out "$ENC" $(pass_args)
    echo "encrypted: $ENC ($(du -h "$ENC" | cut -f1))"
    ;;
unpack)
    [ -f "$ENC" ] || { echo "ERROR: $ENC missing" >&2; exit 1; }
    mkdir -p android/app/src/main/assets
    rm -rf "$ASSETS"
    openssl enc -d -aes-256-cbc -pbkdf2 -in "$ENC" -out /tmp/.h3scenes.tgz $(pass_args)
    tar -xzf /tmp/.h3scenes.tgz -C android/app/src/main/assets
    rm -f /tmp/.h3scenes.tgz
    echo "unpacked: $ASSETS ($(ls "$ASSETS" | wc -l | tr -d ' ') files)"
    ;;
*)
    echo "usage: $0 encrypt | unpack" >&2
    exit 1
    ;;
esac
