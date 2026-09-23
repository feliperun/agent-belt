#!/usr/bin/env bash
# Regenerates assets/overlay.gif from the real overlay drawing code.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
clang -fobjc-arc -fblocks -w -I"$root/src" "$root/tools/render-overlay.m" "$root/src/macos_shim.c" "$root/src/knob.m" \
  -framework AppKit -framework IOKit -framework AudioToolbox -framework CoreAudio -framework ImageIO \
  -framework UniformTypeIdentifiers -o "$tmp/render-overlay"
"$tmp/render-overlay" "$root/assets/overlay.gif"
echo "assets/overlay.gif ($(du -h "$root/assets/overlay.gif" | cut -f1))"
