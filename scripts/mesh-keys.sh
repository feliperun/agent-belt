#!/usr/bin/env bash
# mesh-keys.sh [--dry-run]
#
# Makes every machine in the registry able to ssh into every other one.
# Idempotent: run it as often as you like. Two things break a pair:
#
#   1. authorized_keys without the source's key -> "Permission denied (publickey)"
#   2. known_hosts with an old host key         -> "HOST IDENTIFICATION HAS CHANGED"
#
# (2) is common because a reinstalled machine gets a new host key, and only a
# machine that never connected before does not notice. The script fixes both.
#
# Only `posix` machines are changed. On Windows the user's authorized_keys is
# ignored for administrator accounts: sshd reads
# C:\ProgramData\ssh\administrators_authorized_keys, with an ACL limited to
# SYSTEM + Administrators, and editing it needs care with the DACL. Windows
# already accepts the other machines, so the script only reports what is missing.

# No -e on purpose: a mesh pass must report every offline machine, and this
# script reads failures (an unreachable ssh, a grep that matches nothing) as
# results to print rather than reasons to stop.
set -uo pipefail

CONFIG="${WORK_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/work/hosts.conf}"
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new)
dry=0
[ "${1:-}" = "--dry-run" ] && dry=1

die() { printf 'mesh-keys: %s\n' "$*" >&2; exit 1; }

[ -f "$CONFIG" ] || die "no registry at $CONFIG (run: agb hosts discover)"

NAMES=(); TARGETS=(); KINDS=(); SELF=""
while read -r kw a b c || [ -n "$kw" ]; do
  case "$kw" in
    host) NAMES+=("$a"); TARGETS+=("$b"); KINDS+=("${c:-posix}") ;;
    self) SELF="$a" ;;
  esac
done < "$CONFIG"

# This machine is not reached over ssh: loopback is rarely authorized, and
# does not need to be.
is_self() { [ "$1" = "$SELF" ]; }

tmp=$(mktemp -d "${TMPDIR:-/tmp}/meshkeys.XXXXXX") || die "no temporary directory"
trap 'rm -rf "$tmp"' EXIT

# Taking each machine's ~/.ssh/id_ed25519.pub is not enough: ~/.ssh/config may
# force a different IdentityFile per target (one machine can offer
# id_ed25519_tailnet_mesh to some hosts and id_ed25519 to others). The source's
# own ssh knows: `ssh -G <target>` prints, resolved, what it will offer.
printf '== collecting the keys each machine offers to each target\n'
cat > "$tmp/collect.sh" <<'COL'
case "$(uname -s)" in MSYS*|MINGW*) PATH="$PATH:/c/Windows/System32/OpenSSH" ;; esac
while read -r t; do
  [ -n "$t" ] || continue
  ssh -G "$t" 2>/dev/null | awk '$1 == "identityfile" { print $2 }' | while read -r f; do
    case "$f" in "~/"*) f="$HOME/${f#\~/}" ;; esac
    [ -f "$f.pub" ] || continue
    printf '%s %s\n' "$t" "$(head -1 "$f.pub")"
  done
done
COL

for ((i = 0; i < ${#NAMES[@]}; i++)); do
  name="${NAMES[$i]}"
  : > "$tmp/targets"
  for ((j = 0; j < ${#NAMES[@]}; j++)); do
    [ "$j" = "$i" ] && continue
    printf '%s\n' "${TARGETS[$j]}" >> "$tmp/targets"
  done
  cat "$tmp/collect.sh" "$tmp/targets" > "$tmp/send"
  if is_self "$name"; then
    bash "$tmp/collect.sh" < "$tmp/targets" > "$tmp/offers.$name" 2>/dev/null
  elif [ "${KINDS[$i]}" = msys ]; then
    ssh "${SSH_OPTS[@]}" "${TARGETS[$i]}" 'C:\msys64\usr\bin\bash.exe -l -s' < "$tmp/send" 2>/dev/null \
      | tr -d '\r' > "$tmp/offers.$name"
  else
    ssh "${SSH_OPTS[@]}" "${TARGETS[$i]}" 'bash -s' < "$tmp/send" 2>/dev/null > "$tmp/offers.$name"
  fi
  n=0
  [ -f "$tmp/offers.$name" ] && n=$(grep -c ' ssh-' "$tmp/offers.$name")
  if [ "$n" -gt 0 ]; then
    printf '   %-18s %s key(s) offered\n' "$name" "$n"
  else
    printf '   %-18s NONE (offline, or no key in ~/.ssh)\n' "$name"
  fi
done

APPEND='mkdir -p ~/.ssh; chmod 700 ~/.ssh; touch ~/.ssh/authorized_keys; chmod 600 ~/.ssh/authorized_keys; a=0
while read -r t b c; do
  [ -n "$b" ] || continue
  if ! grep -qF "$b" ~/.ssh/authorized_keys; then printf "%s %s %s\n" "$t" "$b" "$c" >> ~/.ssh/authorized_keys; a=$((a+1)); fi
done
echo "new keys: $a"'

printf '\n== distributing\n'
for ((i = 0; i < ${#NAMES[@]}; i++)); do
  name="${NAMES[$i]}"; target="${TARGETS[$i]}"
  if [ "${KINDS[$i]}" = msys ]; then
    printf '   %-18s skipped (Windows: see the header of this script)\n' "$name"
    continue
  fi
  # What each source offers *to this machine*, the comment saying whose key it is.
  : > "$tmp/push"
  for ((j = 0; j < ${#NAMES[@]}; j++)); do
    [ "$j" = "$i" ] && continue
    [ -f "$tmp/offers.${NAMES[$j]}" ] || continue
    awk -v dest="$target" -v n="${NAMES[$j]}" \
      '$1 == dest && $2 ~ /^ssh-/ { print $2, $3, "work-mesh-" n }' \
      "$tmp/offers.${NAMES[$j]}" >> "$tmp/push"
  done
  sort -u -k2,2 "$tmp/push" -o "$tmp/push"
  if [ "$dry" = 1 ]; then
    printf '   %-18s would receive %s key(s)\n' "$name" "$(wc -l < "$tmp/push" | tr -d ' ')"
    continue
  fi
  printf '   %-18s ' "$name"
  if is_self "$name"; then
    bash -c "$APPEND" < "$tmp/push" 2>&1 | tail -1
  else
    ssh "${SSH_OPTS[@]}" "$target" "$APPEND" < "$tmp/push" 2>&1 | tail -1
  fi
done

# ------------------------------------------------------------- host keys --
#
# A reinstalled machine gets a new host key, and whoever had the old one refuses
# the connection before even authenticating. The reference is the known_hosts
# of the machine running this script: it reaches every machine, so what it has
# stored wins. Only without a local record is the key read from the network
# (ssh-keyscan).
printf '\n== host keys\n'
: > "$tmp/hostkeys"
for ((i = 0; i < ${#NAMES[@]}; i++)); do
  h="${TARGETS[$i]#*@}"
  stored=$(ssh-keygen -F "$h" 2>/dev/null | grep -v '^#' | awk '$2 == "ssh-ed25519" { print $3 }' | head -1)
  if [ -z "$stored" ]; then
    stored=$(ssh-keyscan -t ed25519 "$h" 2>/dev/null | awk '{ print $3 }' | head -1)
    [ -n "$stored" ] && printf '   %-18s read from the network (not known locally)\n' "$h"
  fi
  if [ -z "$stored" ]; then
    printf '   %-18s NO HOST KEY (machine offline?)\n' "$h"
    continue
  fi
  printf '%s %s\n' "$h" "$stored" >> "$tmp/hostkeys"
done

{
  printf 'DRY=%s\n' "$dry"
  cat <<'FIX'
case "$(uname -s)" in MSYS*|MINGW*) PATH="$PATH:/c/Windows/System32/OpenSSH" ;; esac
mkdir -p ~/.ssh; chmod 700 ~/.ssh; touch ~/.ssh/known_hosts
while read -r h k; do
  [ -n "$k" ] || continue
  s=$(ssh-keygen -F "$h" 2>/dev/null | grep -v '^#' | head -1 | cut -d' ' -f3)
  if [ -z "$s" ]; then
    echo "      $h: not known yet (learned on the first connection)"
  elif [ "$s" = "$k" ]; then
    echo "      $h: ok"
  elif [ "$DRY" = 1 ]; then
    echo "      $h: host key STALE (would be updated)"
  else
    ssh-keygen -R "$h" >/dev/null 2>&1
    printf '%s ssh-ed25519 %s\n' "$h" "$k" >> ~/.ssh/known_hosts
    echo "      $h: host key UPDATED"
  fi
done
FIX
} > "$tmp/fixhk.sh"

# The script and the host key list travel on the same stdin: the final
# `while read` consumes what comes after `done`. It is the only way to send a
# script *and* data to Windows, where a quoted argument does not survive sshd's
# `powershell -c`.
for ((i = 0; i < ${#NAMES[@]}; i++)); do
  printf '   on %s:\n' "${NAMES[$i]}"
  grep -v "^${TARGETS[$i]#*@} " "$tmp/hostkeys" > "$tmp/hk.in"
  if is_self "${NAMES[$i]}"; then
    bash "$tmp/fixhk.sh" < "$tmp/hk.in"
  else
    cat "$tmp/fixhk.sh" "$tmp/hk.in" > "$tmp/hk.send"
    if [ "${KINDS[$i]}" = msys ]; then
      ssh "${SSH_OPTS[@]}" "${TARGETS[$i]}" 'C:\msys64\usr\bin\bash.exe -l -s' < "$tmp/hk.send" 2>&1 | tr -d '\r'
    else
      ssh "${SSH_OPTS[@]}" "${TARGETS[$i]}" 'bash -s' < "$tmp/hk.send" 2>&1
    fi | grep -E ': ok$|: host key|: not known yet'
  fi
done

printf '\n== checking the mesh (this can take a few seconds)\n'

# The probe goes on stdin, not as an argument: the only way to send a script
# with quotes to Windows, where sshd wraps everything in `powershell -c` and
# destroys shell quoting. `bash -s` reads the script from stdin on both.
for ((i = 0; i < ${#NAMES[@]}; i++)); do
  printf '   from %s:\n' "${NAMES[$i]}"
  {
    # On MSYS2 ssh is Windows' own and not on the login shell's PATH.
    printf 'case "$(uname -s)" in MSYS*|MINGW*) PATH="$PATH:/c/Windows/System32/OpenSSH" ;; esac\n'
    printf 'for t in'
    for ((j = 0; j < ${#NAMES[@]}; j++)); do
      [ "$j" = "$i" ] && continue
      printf ' %s' "${TARGETS[$j]}"
    done
    printf '; do\n'
    printf '  if ssh -n -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new "$t" echo OK 2>/dev/null | tr -d "\\r" | grep -qx OK; then\n'
    printf '    echo "      $t ok"\n  else\n    echo "      $t FAILED"\n  fi\ndone\n'
  } > "$tmp/probe.sh"

  if is_self "${NAMES[$i]}"; then
    bash "$tmp/probe.sh"
  elif [ "${KINDS[$i]}" = msys ]; then
    # -l with -s: without a login shell MSYS2 does not even put /usr/bin on the
    # PATH, and the script dies with "uname: command not found".
    ssh "${SSH_OPTS[@]}" "${TARGETS[$i]}" 'C:\msys64\usr\bin\bash.exe -l -s' < "$tmp/probe.sh" 2>&1 \
      | tr -d '\r' | grep -E ' ok$| FAILED$'
  else
    ssh "${SSH_OPTS[@]}" "${TARGETS[$i]}" 'bash -s' < "$tmp/probe.sh" 2>&1 | grep -E ' ok$| FAILED$'
  fi
done
