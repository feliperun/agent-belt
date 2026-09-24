#!/usr/bin/env bash
# update.sh [tag]: installs the latest (or the given) Agent Belt release from
# source with ./install.sh, so the app is signed locally and keeps its macOS
# privacy grants. Started by `agb update` or the update notification.
set -euo pipefail
repo=feliperun/agent-belt
tag="${1:-}"
if [ -z "$tag" ]; then
  tag=$(curl -fsSL "https://api.github.com/repos/$repo/releases/latest" |
    sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -1)
fi
[ -n "$tag" ] || { echo "update.sh: no release found" >&2; exit 1; }
command -v zig >/dev/null || { echo "update.sh: needs zig (brew install zig)" >&2; exit 1; }
dir=$(mktemp -d)
echo "==> downloading $tag"
curl -fsSL "https://github.com/$repo/archive/refs/tags/$tag.tar.gz" | tar -xz -C "$dir" --strip-components 1
cd "$dir"
./install.sh
