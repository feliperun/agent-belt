#!/usr/bin/env bash
# deploy.sh <maquina>...        instala/atualiza o work nas maquinas indicadas
# deploy.sh --all               em todas as registradas (menos esta)
#
# Nomes e destinos saem do registro local (~/.config/work/hosts.conf), entao
# `work hosts discover` antes. O mesmo registro vai junto para a maquina de
# destino (so a linha `self` muda): redescobrir do outro lado erraria o usuario
# de quem nao esta no ~/.ssh/config de la -- Micromed@felipe-windows viraria
# frb@felipe-windows. Windows (tipo msys) recebe tambem o profile do PowerShell.

set -uo pipefail

src=$(cd "$(dirname "$0")/.." && pwd)
CONFIG="${WORK_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/work/hosts.conf}"
SSH_OPTS=(-o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new)

die() { printf 'deploy: %s\n' "$*" >&2; exit 1; }

[ -f "$CONFIG" ] || die "sem registro em $CONFIG (rode: work hosts discover)"

NAMES=(); TARGETS=(); KINDS=(); SELF_NAME=""
while read -r kw a b c || [ -n "$kw" ]; do
  case "$kw" in
    ''|'#'*) continue ;;
    self)    SELF_NAME="$a" ;;
    host)    NAMES+=("$a"); TARGETS+=("$b"); KINDS+=("${c:-posix}") ;;
  esac
done < "$CONFIG"

[ $# -gt 0 ] || die "usage: deploy.sh <maquina>... | --all"

wanted=()
if [ "${1:-}" = "--all" ]; then
  for ((i = 0; i < ${#NAMES[@]}; i++)); do
    [ "${NAMES[$i]}" = "$SELF_NAME" ] && continue
    wanted+=("${NAMES[$i]}")
  done
else
  wanted=("$@")
fi

deploy_one() {
  local name="$1" i idx=-1 target kind user
  for ((i = 0; i < ${#NAMES[@]}; i++)); do
    [ "${NAMES[$i]}" = "$name" ] && idx=$i
  done
  [ "$idx" -ge 0 ] || { printf '%-18s NAO ESTA NO REGISTRO\n' "$name"; return 1; }
  target="${TARGETS[$idx]}"; kind="${KINDS[$idx]}"; user="${target%@*}"

  printf '== %s (%s, %s)\n' "$name" "$target" "$kind"

  if [ "$kind" = msys ]; then
    # O sftp do Windows abre no perfil do usuario. O mkdir vai em PowerShell
    # puro: o sshd de la ja embrulha o comando em `powershell -c`, e uma linha
    # sem aspas atravessa intacta (barra invertida escapando espaco, que e o
    # que o bash esperaria, o PowerShell nao entende).
    ssh -n "${SSH_OPTS[@]}" "$target" \
      'New-Item -Force -ItemType Directory $env:USERPROFILE\.local\bin, $env:USERPROFILE\Documents\WindowsPowerShell, $env:USERPROFILE\.config\work' >/dev/null 2>&1
  else
    ssh -n "${SSH_OPTS[@]}" "$target" 'mkdir -p ~/.local/bin' || { printf '   FALHOU: ssh\n'; return 1; }
  fi

  scp -q "${SSH_OPTS[@]}" "$src/bin/work" "$src/bin/work-session" "$src/bin/tm" \
    "$target:.local/bin/" || { printf '   FALHOU: scp dos scripts\n'; return 1; }

  # Registro identico em todas as maquinas; muda so quem e `self`.
  [ "$kind" = msys ] || ssh -n "${SSH_OPTS[@]}" "$target" 'mkdir -p ~/.config/work' >/dev/null 2>&1
  scp -q "${SSH_OPTS[@]}" "$CONFIG" "$target:.config/work/hosts.conf" \
    || printf '   aviso: registro nao copiado\n'

  if [ "$kind" = msys ]; then
    scp -q "${SSH_OPTS[@]}" "$src/windows/Microsoft.PowerShell_profile.ps1" \
      "$target:Documents/WindowsPowerShell/Microsoft.PowerShell_profile.ps1" \
      || printf '   aviso: profile do PowerShell nao copiado\n'
    # Sem chmod no Windows: la o `work` sempre entra por `bash -l <script>`,
    # que nao precisa do bit de execucao.
    ssh -n "${SSH_OPTS[@]}" "$target" \
      "C:\\msys64\\usr\\bin\\bash.exe -l /c/Users/$user/.local/bin/work hosts self $name" 2>&1 | tr -d '\r' | sed 's/^/   /'
  else
    ssh -n "${SSH_OPTS[@]}" "$target" \
      "chmod +x ~/.local/bin/work ~/.local/bin/work-session ~/.local/bin/tm; ln -sf ~/.local/bin/work ~/.local/bin/rwork; ~/.local/bin/work hosts self $name" \
      2>&1 | sed 's/^/   /'
  fi
  printf '   ok\n'
}

rc=0
for name in ${wanted[@]+"${wanted[@]}"}; do
  deploy_one "$name" || rc=1
done
exit "$rc"
