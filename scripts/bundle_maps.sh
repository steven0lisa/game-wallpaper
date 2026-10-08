#!/bin/bash
# Maintains the encrypted copies of the bundled XL maps:
#   scripts/bundle_maps.sh encrypt   re-encrypt the listed maps from MAP_SRC (default: vcmi Maps) -> Resources/BundledMaps/*.h3m.enc
#   scripts/bundle_maps.sh decrypt <out_dir>   decrypt all listed maps into a directory (needs BUNDLED_MAPS_PASS or PASS_FILE)
# Password source: the BUNDLED_MAPS_PASS env var, or PASS_FILE (default ~/.config/gamewallpaper/bundled-maps-pass).
# Plain-text .h3m never enters the repo (.gitignore); encrypted copies may; the
# password lives only in the local PASS_FILE and the GitHub secret.
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
