#!/usr/bin/env bash
# mesh-keys.sh [--dry-run]
#
# Deixa cada maquina do registro capaz de abrir ssh em todas as outras.
# Idempotente -- roda quantas vezes quiser. Duas coisas derrubam um par:
#
#   1. authorized_keys sem a chave da origem -> "Permission denied (publickey)"
#   2. known_hosts com host key velha        -> "HOST IDENTIFICATION HAS CHANGED"
#
# O (2) e comum aqui porque maquina reinstalada troca a host key e so quem
# nunca conectou antes nao percebe. O script trata os dois.
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

# Nao basta pegar ~/.ssh/id_ed25519.pub de cada maquina: o ~/.ssh/config pode
# forcar uma IdentityFile diferente por destino (a felipe-windows oferece
# id_ed25519_tailnet_mesh para uns hosts e id_ed25519 para outros). Quem sabe a
# resposta certa e o proprio ssh da origem: `ssh -G <destino>` lista, ja
# resolvido, o que ele vai oferecer.
printf '== coletando as chaves que cada maquina oferece a cada destino\n'
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
    printf '   %-18s %s chave(s) oferecida(s)\n' "$name" "$n"
  else
    printf '   %-18s NADA (fora do ar, ou sem chave em ~/.ssh)\n' "$name"
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
  # O que cada origem oferece *para esta maquina*, com o comentario dizendo de
  # quem e a chave.
  : > "$tmp/push"
  for ((j = 0; j < ${#NAMES[@]}; j++)); do
    [ "$j" = "$i" ] && continue
    [ -f "$tmp/offers.${NAMES[$j]}" ] || continue
    awk -v alvo="$target" -v n="${NAMES[$j]}" \
      '$1 == alvo && $2 ~ /^ssh-/ { print $2, $3, "work-mesh-" n }' \
      "$tmp/offers.${NAMES[$j]}" >> "$tmp/push"
  done
  sort -u -k2,2 "$tmp/push" -o "$tmp/push"
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

# ------------------------------------------------------------- host keys --
#
# Maquina reinstalada troca a host key, e quem ja tinha o registro antigo passa
# a recusar a conexao antes mesmo de tentar autenticar. A referencia e o
# known_hosts de quem esta rodando este script: ele alcanca todas as maquinas,
# entao o que esta guardado aqui e o que vale. So na falta de registro local a
# chave e lida da rede (ssh-keyscan).
printf '\n== host keys\n'
: > "$tmp/hostkeys"
for ((i = 0; i < ${#NAMES[@]}; i++)); do
  h="${TARGETS[$i]#*@}"
  stored=$(ssh-keygen -F "$h" 2>/dev/null | grep -v '^#' | awk '$2 == "ssh-ed25519" { print $3 }' | head -1)
  if [ -z "$stored" ]; then
    stored=$(ssh-keyscan -t ed25519 "$h" 2>/dev/null | awk '{ print $3 }' | head -1)
    [ -n "$stored" ] && printf '   %-18s lida da rede (sem registro local)\n' "$h"
  fi
  if [ -z "$stored" ]; then
    printf '   %-18s SEM HOST KEY (maquina fora do ar?)\n' "$h"
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
    echo "      $h: sem registro (aprende no primeiro acesso)"
  elif [ "$s" = "$k" ]; then
    echo "      $h: ok"
  elif [ "$DRY" = 1 ]; then
    echo "      $h: host key ANTIGA (seria atualizada)"
  else
    ssh-keygen -R "$h" >/dev/null 2>&1
    printf '%s ssh-ed25519 %s\n' "$h" "$k" >> ~/.ssh/known_hosts
    echo "      $h: host key ATUALIZADA"
  fi
done
FIX
} > "$tmp/fixhk.sh"

# O script e a lista de host keys viajam no mesmo stdin: o `while read` do
# final consome o que vier depois do `done`. E o unico jeito de mandar script
# *e* dados para o Windows, onde argumento com aspas nao sobrevive ao
# `powershell -c` do sshd.
for ((i = 0; i < ${#NAMES[@]}; i++)); do
  printf '   em %s:\n' "${NAMES[$i]}"
  grep -v "^${TARGETS[$i]#*@} " "$tmp/hostkeys" > "$tmp/hk.in"
  if is_self "${NAMES[$i]}"; then
    bash "$tmp/fixhk.sh" < "$tmp/hk.in"
  else
    cat "$tmp/fixhk.sh" "$tmp/hk.in" > "$tmp/hk.send"
    if [ "${KINDS[$i]}" = msys ]; then
      ssh "${SSH_OPTS[@]}" "${TARGETS[$i]}" 'C:\msys64\usr\bin\bash.exe -l -s' < "$tmp/hk.send" 2>&1 | tr -d '\r'
    else
      ssh "${SSH_OPTS[@]}" "${TARGETS[$i]}" 'bash -s' < "$tmp/hk.send" 2>&1
    fi | grep -E ': ok$|: host key|: sem registro'
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
