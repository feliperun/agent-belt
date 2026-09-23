#!/usr/bin/env bash
# Regenerates assets/AppIcon.icns (and assets/icon.png) from tools/make-icon.m.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
clang -fobjc-arc -framework AppKit "$root/tools/make-icon.m" -o "$tmp/make-icon"
"$tmp/make-icon" "$root/assets/icon.png"
set_dir="$tmp/AppIcon.iconset"
mkdir -p "$set_dir"
for size in 16 32 128 256 512; do
  sips -z $size $size "$root/assets/icon.png" --out "$set_dir/icon_${size}x${size}.png" >/dev/null
  sips -z $((size * 2)) $((size * 2)) "$root/assets/icon.png" --out "$set_dir/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$set_dir" -o "$root/assets/AppIcon.icns"
echo "assets/AppIcon.icns"
