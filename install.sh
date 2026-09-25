#!/usr/bin/env bash
# install.sh [--keep-config] | --uninstall | --package <dir>
#
# Installs Agent Belt as a background app: builds it, bundles it into
# ~/Applications/Agent Belt.app, signs it, stores the Deepgram key in the
# Keychain and registers a LaunchAgent that starts at login and restarts it.
#
# Configuration lives in code (src/config.zig): every install regenerates
# ~/.config/agent-belt/config.json from the defaults. --keep-config keeps the
# current file.

set -euo pipefail

label=com.frb.agentbelt
app="$HOME/Applications/Agent Belt.app"
exe="$app/Contents/MacOS/agb"
plist="$HOME/Library/LaunchAgents/$label.plist"
log="$HOME/Library/Logs/agent-belt.log"
link="$HOME/.local/bin/agb"
domain="gui/$(id -u)"
src=$(cd "$(dirname "$0")" && pwd)

say() { printf '\033[1m==>\033[0m %s\n' "$*"; }
die() { printf 'install.sh: %s\n' "$*" >&2; exit 1; }

# Stores the Deepgram key in the login Keychain. The key goes on `security`'s
# standard input, never in its arguments: on macOS any local user reads another
# process's arguments (`ps -axo args`), so `-w <key>` would hand the key over
# for as long as the command runs. `security -i` reads the same command from
# stdin, where only this user can look.
# store_key <key> [-U]
store_key() {
  local escape='s/[\\"]/\\&/g'
  printf 'add-generic-password %s-s agent-belt -a deepgram -T "%s" -w "%s"\n' \
    "${2:+$2 }" "$(printf '%s' "$app" | sed "$escape")" "$(printf '%s' "$1" | sed "$escape")" |
    security -i >/dev/null
}

# Stops the LaunchAgent and any daemon started by hand in a terminal: two
# daemons would double every key.
stop_daemons() {
  # launchctl bootout waits for the daemon to exit, and has waited for minutes
  # with it still running ("languishing"). So it runs in the background while
  # the daemon is ended here: SIGTERM until bootout returns, SIGKILL at the end.
  launchctl bootout "$domain/com.frb.minikeyboard" 2>/dev/null || true # before the rename
  launchctl bootout "$domain/$label" 2>/dev/null &
  local bootout=$!
  for _ in $(seq 1 50); do
    kill -0 "$bootout" 2>/dev/null || break
    pkill -f '/(agb|agent-belt|minikeyboard) daemon$' 2>/dev/null || true
    sleep 0.2
  done
  pkill -9 -f '/(agb|agent-belt|minikeyboard) daemon$' 2>/dev/null || true
  wait "$bootout" 2>/dev/null || true
}

keep_config=0
package=""
case "${1:-}" in
  --package) package="${2:?install.sh: --package needs a directory}" ;;
  --uninstall)
    say "removing the LaunchAgent, the app and the link"
    stop_daemons
    rm -f "$plist" "$link" "$HOME/.local/bin/agent-belt"
    rm -rf "$app"
    say "done. The config (~/.config/agent-belt) and the Keychain key were kept;"
    printf '    to delete the key: security delete-generic-password -s agent-belt -a deepgram\n'
    # The recordings outlive the app: whoever uninstalls it should be told where.
    printf '    your recordings and transcripts stay in "%s":\n' "$HOME/Library/Application Support/agent-belt/history"
    printf '    to delete them: rm -rf ~/Library/Application\\ Support/agent-belt\n'
    exit 0 ;;
  --keep-config) keep_config=1 ;;
  "") ;;
  -h|--help) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) die "unknown option: $1" ;;
esac

[ "$(uname -s)" = Darwin ] || die "runs on macOS only"
command -v zig >/dev/null || die "zig not found (brew install zig)"

say "building (ReleaseSafe)"
(cd "$src" && zig build -Doptimize=ReleaseSafe)

version=$(tr -d " \n" < "$src/version.txt")
stage="$(mktemp -d)/Agent Belt.app"
mkdir -p "$stage/Contents/MacOS" "$stage/Contents/Resources"
cp "$src/assets/AppIcon.icns" "$stage/Contents/Resources/AppIcon.icns"
cp "$src/scripts/update.sh" "$stage/Contents/Resources/update.sh"
cp "$src/zig-out/bin/agb" "$stage/Contents/MacOS/agb"
cat > "$stage/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>$label</string>
  <key>CFBundleName</key><string>Agent Belt</string>
  <key>CFBundleExecutable</key><string>agb</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$version</string>
  <key>CFBundleVersion</key><string>$version</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>O agent-belt grava sua voz enquanto a tecla de push-to-talk esta pressionada para transcrever com o Deepgram.</string>
</dict></plist>
PLIST

# Privacy grants (Input Monitoring, Accessibility, Microphone) are tied to the
# signature. With a certificate the requirement is "this bundle id + this
# certificate" and survives every rebuild; an ad hoc signature changes each time.
identity="${AGENT_BELT_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null |
  sed -n 's/.*"\(Apple Development: [^"]*\)".*/\1/p' | head -1)}"
if [ -z "$identity" ]; then
  identity=-
  say "no signing certificate: signing ad hoc (privacy permissions must be granted again after each update)"
fi
say "signing with: $identity"
codesign --force --sign "$identity" --identifier "$label" "$stage" >/dev/null

# --package: just the signed app, zipped (used by the release workflow).
if [ -n "$package" ]; then
  mkdir -p "$package"
  zip="$(cd "$package" && pwd)/Agent-Belt-$version-macos.zip"
  (cd "$(dirname "$stage")" && ditto -c -k --keepParent "Agent Belt.app" "$zip")
  say "package: $zip"
  exit 0
fi

say "stopping running daemons"
stop_daemons
mkdir -p "$(dirname "$app")"
rm -rf "$app"
mv "$stage" "$app"

mkdir -p "$(dirname "$link")"
ln -sf "$exe" "$link"
ln -sf "$exe" "$HOME/.local/bin/agent-belt" # long alias

# The project was called minikeyboard: drop that install (its privacy grants
# and Keychain item stay behind under the old identity).
rm -f "$HOME/Library/LaunchAgents/com.frb.minikeyboard.plist" "$HOME/.local/bin/minikeyboard"
rm -rf "$HOME/Applications/Minikeyboard.app"
[ -f "$HOME/.config/minikeyboard/config.json" ] && [ ! -f "$HOME/.config/agent-belt/config.json" ] &&
  mkdir -p "$HOME/.config/agent-belt" && cp "$HOME/.config/minikeyboard/config.json" "$HOME/.config/agent-belt/"

# agb now runs agent sessions itself: drop the old bash work/work-session/tm.
rm -f "$HOME/.local/bin/work" "$HOME/.local/bin/work-session" "$HOME/.local/bin/tm"

if [ "$keep_config" = 0 ]; then
  say "config regenerated from src/config.zig"
  "$exe" init >/dev/null 2>&1
fi

# The LaunchAgent does not inherit the shell's environment: the key goes to the
# Keychain, readable by the app without a prompt.
# Only written when missing (or with AGENT_BELT_UPDATE_KEY=1): changing an
# existing item opens a Keychain dialog that would stall the install.
if security find-generic-password -s agent-belt -a deepgram >/dev/null 2>&1 &&
    [ "${AGENT_BELT_UPDATE_KEY:-0}" != 1 ]; then
  say "the Deepgram key is already in the Keychain"
elif [ -n "${DEEPGRAM_API_KEY:-}" ]; then
  say "storing DEEPGRAM_API_KEY in the Keychain"
  security delete-generic-password -s agent-belt -a deepgram >/dev/null 2>&1 || true
  store_key "$DEEPGRAM_API_KEY"
else
  if [ -t 0 ]; then
    read -rsp "Deepgram key: " key; echo
    [ -n "$key" ] && store_key "$key" -U
  else
    say "no Deepgram key: push-to-talk fails until this runs again with DEEPGRAM_API_KEY"
  fi
fi

mkdir -p "$(dirname "$plist")" "$(dirname "$log")"
cat > "$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$label</string>
  <key>ProgramArguments</key><array><string>$exe</string><string>daemon</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>5</integer>
  <key>ProcessType</key><string>Interactive</string>
  <key>LimitLoadToSessionType</key><string>Aqua</string>
  <key>EnvironmentVariables</key><dict>
    <key>PATH</key><string>$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/Applications/Orca.app/Contents/Resources/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    <key>LANG</key><string>en_US.UTF-8</string>
  </dict>
  <key>StandardOutPath</key><string>$log</string>
  <key>StandardErrorPath</key><string>$log</string>
</dict></plist>
PLIST

say "starting the LaunchAgent"
launchctl bootstrap "$domain" "$plist"
launchctl enable "$domain/$label"
launchctl kickstart -k "$domain/$label" >/dev/null

sleep 1
if launchctl print "$domain/$label" 2>/dev/null | grep -q 'state = running'; then
  say "running ($version). Log: $log"
else
  say "the LaunchAgent is not running; see $log"
fi
cat <<MSG

The first time, allow "Agent Belt" in System Settings > Privacy & Security:
Input Monitoring and Accessibility (the daemon retries on its own every ~15 s),
and the Microphone on the first push-to-talk.

  agb agents list               CLI (linked at $link)
  tail -f $log
  ./install.sh --uninstall
MSG
