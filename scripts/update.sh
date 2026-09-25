#!/usr/bin/env bash
# update.sh [tag]: installs the latest (or the given) Agent Belt release from
# source with ./install.sh, so the app is signed locally and keeps its macOS
# privacy grants. Started by `agb update` or the update notification.
set -euo pipefail
repo=feliperun/agent-belt
# https end to end: --proto-redir keeps a redirect from downgrading a transfer
# to plaintext, where anyone on the path could hand us the sources to build.
curl_opts=(--fail --silent --show-error --location --proto '=https' --proto-redir '=https' --max-time 600)

tag="${1:-}"
if [ -z "$tag" ]; then
  tag=$(curl "${curl_opts[@]}" "https://api.github.com/repos/$repo/releases/latest" |
    sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -1)
fi
# The tag becomes part of a URL: only a release tag shape, never a path of its own.
case "$tag" in
  "" | *[!A-Za-z0-9.+_-]* | *..*) echo "update.sh: not a release tag: '$tag'" >&2; exit 1 ;;
esac
command -v zig >/dev/null || { echo "update.sh: needs zig (brew install zig)" >&2; exit 1; }

dir=$(mktemp -d)
trap 'rm -rf "$dir"' EXIT
echo "==> downloading $tag"
# Fetched whole, then unpacked: a transfer cut short must not leave a partial
# tree that install.sh would go on to build, sign and register.
curl "${curl_opts[@]}" -o "$dir/source.tar.gz" "https://github.com/$repo/archive/refs/tags/$tag.tar.gz"
mkdir "$dir/source"
tar -xzf "$dir/source.tar.gz" -C "$dir/source" --strip-components 1
[ -x "$dir/source/install.sh" ] || { echo "update.sh: $tag carries no installer" >&2; exit 1; }
cd "$dir/source"
./install.sh
