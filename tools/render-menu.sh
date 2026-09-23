#!/usr/bin/env bash
# Regenerates assets/menu.png from the real agent menu drawing code.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
clang -fobjc-arc -fblocks -w -I"$root/src" "$root/tools/render-menu.m" "$root/src/macos_shim.c" "$root/src/knob.m" \
  -framework AppKit -framework IOKit -framework AudioToolbox -framework CoreAudio -o "$tmp/render-menu"
"$tmp/render-menu" "$root/assets/menu.png"
echo "assets/menu.png"
