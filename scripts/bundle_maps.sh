#!/bin/bash
# 维护内置大地图的加密副本：
#   scripts/bundle_maps.sh encrypt   从 MAP_SRC（默认 vcmi Maps）重新加密清单地图 → Resources/BundledMaps/*.h3m.enc
#   scripts/bundle_maps.sh decrypt <out_dir>   解密全部清单地图到指定目录（需 BUNDLED_MAPS_PASS 或 PASS_FILE）
# 密码来源：BUNDLED_MAPS_PASS 环境变量，或 PASS_FILE（默认 ~/.config/gamewallpaper/bundled-maps-pass）
# 明文 .h3m 永不入库（.gitignore）；加密副本可入库，密码只存在本地 PASS_FILE 与 GitHub Secret。
set -euo pipefail
cd "$(dirname "$0")/.."

LIST="scripts/bundled_maps.txt"
ENC_DIR="Resources/BundledMaps"
MAP_SRC="${MAP_SRC:-$HOME/Library/Application Support/vcmi/Maps}"
PASS_FILE="${PASS_FILE:-$HOME/.config/gamewallpaper/bundled-maps-pass}"

pass_arg() {
    if [ -n "${BUNDLED_MAPS_PASS:-}" ]; then
        echo "-pass" "env:BUNDLED_MAPS_PASS"
    elif [ -f "$PASS_FILE" ]; then
        echo "-pass" "file:$PASS_FILE"
    else
        echo "ERROR: no BUNDLED_MAPS_PASS env nor PASS_FILE at $PASS_FILE" >&2
        exit 1
    fi
}

cmd="${1:-}"
case "$cmd" in
encrypt)
    mkdir -p "$ENC_DIR"
    while IFS= read -r name; do
        [ -z "$name" ] && continue
        case "$name" in \#*) continue ;; esac
        src="$MAP_SRC/$name"
        [ -f "$src" ] || { echo "ERROR: $src not found" >&2; exit 1; }
        openssl enc -aes-256-cbc -pbkdf2 -salt -in "$src" -out "$ENC_DIR/$name.enc" $(pass_arg)
        echo "encrypted: $name -> $ENC_DIR/$name.enc ($(du -h "$ENC_DIR/$name.enc" | cut -f1))"
    done < "$LIST"
    ;;
decrypt)
    OUT="${2:?usage: bundle_maps.sh decrypt <out_dir>}"
    mkdir -p "$OUT"
    while IFS= read -r name; do
        [ -z "$name" ] && continue
        case "$name" in \#*) continue ;; esac
        enc="$ENC_DIR/$name.enc"
        [ -f "$enc" ] || { echo "ERROR: $enc not found" >&2; exit 1; }
        openssl enc -d -aes-256-cbc -pbkdf2 -in "$enc" -out "$OUT/$name" $(pass_arg)
        echo "decrypted: $name -> $OUT/"
    done < "$LIST"
    ;;
*)
    echo "usage: $0 encrypt | decrypt <out_dir>" >&2
    exit 1
    ;;
esac
