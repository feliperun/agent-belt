#!/usr/bin/env bash
# mesh-keys.sh [--dry-run]
#
# Deixa cada maquina do registro capaz de abrir ssh em todas as outras: coleta
# a chave publica de cada uma e acrescenta as que faltam no authorized_keys das
# demais. Idempotente -- roda quantas vezes quiser.
#
# So maquinas `posix` sao alteradas. No Windows o authorized_keys do usuario e
# ignorado quando a conta e administradora: o sshd usa
# C:\ProgramData\ssh\administrators_authorized_keys, com ACL restrita a SYSTEM
# + Administradores, e mexer nele pede cuidado com a DACL. Como o Windows ja
# aceita as outras maquinas, o script so reporta o que falta la.

set -uo pipefail

CONFIG="${WORK_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/work/hosts.conf}"
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new)
dry=0
[ "${1:-}" = "--dry-run" ] && dry=1

die() { printf 'mesh-keys: %s\n' "$*" >&2; exit 1; }

[ -f "$CONFIG" ] || die "sem registro em $CONFIG (rode: work hosts discover)"

NAMES=(); TARGETS=(); KINDS=(); SELF=""
while read -r kw a b c || [ -n "$kw" ]; do
  case "$kw" in
    host) NAMES+=("$a"); TARGETS+=("$b"); KINDS+=("${c:-posix}") ;;
    self) SELF="$a" ;;
  esac
done < "$CONFIG"

# A propria maquina nao entra por ssh: loopback quase nunca esta autorizado, e
# nao precisa estar.
is_self() { [ "$1" = "$SELF" ]; }

tmp=$(mktemp -d "${TMPDIR:-/tmp}/meshkeys.XXXXXX") || die "sem diretorio temporario"
trap 'rm -rf "$tmp"' EXIT

printf '== coletando chaves publicas\n'
for ((i = 0; i < ${#NAMES[@]}; i++)); do
  name="${NAMES[$i]}"; target="${TARGETS[$i]}"
  if is_self "$name"; then
    cat "$HOME/.ssh/id_ed25519.pub" > "$tmp/$name.raw" 2>/dev/null
  elif [ "${KINDS[$i]}" = msys ]; then
    # PowerShell puro: o sshd do Windows ja embrulha em `powershell -c`, e uma
    # linha sem aspas atravessa intacta.
    ssh -n "${SSH_OPTS[@]}" "$target" \
      'Get-Content $env:USERPROFILE\.ssh\id_ed25519.pub' 2>/dev/null | tr -d '\r' > "$tmp/$name.raw"
  else
    ssh -n "${SSH_OPTS[@]}" "$target" 'cat ~/.ssh/id_ed25519.pub' 2>/dev/null > "$tmp/$name.raw"
  fi
  if grep -q '^ssh-' "$tmp/$name.raw" 2>/dev/null; then
    # Comentario normalizado: authorized_keys legivel diz de quem e cada chave.
    awk -v n="$name" '/^ssh-/ { print $1, $2, "work-mesh-" n }' "$tmp/$name.raw" > "$tmp/$name.pub"
    printf '   %-18s ok\n' "$name"
  else
    printf '   %-18s SEM CHAVE (~/.ssh/id_ed25519.pub); gere com: ssh-keygen -t ed25519\n' "$name"
    rm -f "$tmp/$name.pub"
  fi
done

APPEND='mkdir -p ~/.ssh; chmod 700 ~/.ssh; touch ~/.ssh/authorized_keys; chmod 600 ~/.ssh/authorized_keys; a=0
while read -r t b c; do
  [ -n "$b" ] || continue
  if ! grep -qF "$b" ~/.ssh/authorized_keys; then printf "%s %s %s\n" "$t" "$b" "$c" >> ~/.ssh/authorized_keys; a=$((a+1)); fi
done
echo "chaves novas: $a"'

printf '\n== distribuindo\n'
for ((i = 0; i < ${#NAMES[@]}; i++)); do
  name="${NAMES[$i]}"; target="${TARGETS[$i]}"
  if [ "${KINDS[$i]}" = msys ]; then
    printf '   %-18s pulado (Windows: veja o cabecalho deste script)\n' "$name"
    continue
  fi
  : > "$tmp/push"
  for ((j = 0; j < ${#NAMES[@]}; j++)); do
    [ "$j" = "$i" ] && continue
    [ -f "$tmp/${NAMES[$j]}.pub" ] && cat "$tmp/${NAMES[$j]}.pub" >> "$tmp/push"
  done
  if [ "$dry" = 1 ]; then
    printf '   %-18s receberia %s chave(s)\n' "$name" "$(wc -l < "$tmp/push" | tr -d ' ')"
    continue
  fi
  printf '   %-18s ' "$name"
  if is_self "$name"; then
    bash -c "$APPEND" < "$tmp/push" 2>&1 | tail -1
  else
    ssh "${SSH_OPTS[@]}" "$target" "$APPEND" < "$tmp/push" 2>&1 | tail -1
  fi
done

printf '\n== conferindo o mesh (pode demorar alguns segundos)\n'

# O probe vai por stdin, nao como argumento: e a unica forma de mandar um
# script com aspas para o Windows, onde o sshd embrulha tudo em `powershell -c`
# e destroi quoting de shell. `bash -s` le o script de stdin nos dois mundos.
for ((i = 0; i < ${#NAMES[@]}; i++)); do
  printf '   de %s:\n' "${NAMES[$i]}"
  {
    # No MSYS2 o ssh e o do Windows e nao esta no PATH do login shell.
    printf 'case "$(uname -s)" in MSYS*|MINGW*) PATH="$PATH:/c/Windows/System32/OpenSSH" ;; esac\n'
    printf 'for t in'
    for ((j = 0; j < ${#NAMES[@]}; j++)); do
      [ "$j" = "$i" ] && continue
      printf ' %s' "${TARGETS[$j]}"
    done
    printf '; do\n'
    printf '  if ssh -n -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new "$t" echo OK 2>/dev/null | tr -d "\\r" | grep -qx OK; then\n'
    printf '    echo "      $t ok"\n  else\n    echo "      $t FALHA"\n  fi\ndone\n'
  } > "$tmp/probe.sh"

  if is_self "${NAMES[$i]}"; then
    bash "$tmp/probe.sh"
  elif [ "${KINDS[$i]}" = msys ]; then
    # -l junto com -s: sem o login shell o MSYS2 nao poe nem /usr/bin no PATH,
    # e o script morre em "uname: command not found".
    ssh "${SSH_OPTS[@]}" "${TARGETS[$i]}" 'C:\msys64\usr\bin\bash.exe -l -s' < "$tmp/probe.sh" 2>&1 \
      | tr -d '\r' | grep -E ' ok$| FALHA$'
  else
    ssh "${SSH_OPTS[@]}" "${TARGETS[$i]}" 'bash -s' < "$tmp/probe.sh" 2>&1 | grep -E ' ok$| FALHA$'
  fi
done
