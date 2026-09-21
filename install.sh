#!/usr/bin/env bash
# install.sh [--self <nome-tailnet>] [--no-discover]
#
# Instala o `work`, o `work-session` e o `tm` em ~/.local/bin desta maquina, e
# registra as maquinas do tailnet. Roda igual em macOS, Linux e Windows (MSYS2).

set -uo pipefail

src=$(cd "$(dirname "$0")" && pwd)
dest="${WORK_BIN_DIR:-$HOME/.local/bin}"
orig_path="$PATH"
self=""
discover=1

while [ $# -gt 0 ]; do
  case "$1" in
    --self)        self="${2:-}"; shift 2 ;;
    --no-discover) discover=0; shift ;;
    -h|--help)     sed -n '2,7p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)             printf 'install.sh: opcao desconhecida: %s\n' "$1" >&2; exit 1 ;;
  esac
done

case "$(uname -s)" in
  MSYS*|MINGW*|CYGWIN*) platform=windows ;;
  Darwin)               platform=mac ;;
  *)                    platform=linux ;;
esac

mkdir -p "$dest" || { printf 'install.sh: nao consegui criar %s\n' "$dest" >&2; exit 1; }

for f in work work-session tm; do
  cp "$src/bin/$f" "$dest/$f" || exit 1
  chmod +x "$dest/$f"
  printf 'instalado: %s\n' "$dest/$f"
done

# rwork: nome antigo, agora so um apelido do mesmo programa.
ln -sf "$dest/work" "$dest/rwork" 2>/dev/null && printf 'instalado: %s (apelido)\n' "$dest/rwork"

if [ "$platform" = windows ]; then
  psdir="$HOME/Documents/WindowsPowerShell"
  mkdir -p "$psdir"
  cp "$src/windows/Microsoft.PowerShell_profile.ps1" "$psdir/Microsoft.PowerShell_profile.ps1" \
    && printf 'instalado: %s\n' "$psdir/Microsoft.PowerShell_profile.ps1"
fi

export PATH="$dest:$PATH"

[ -n "$self" ] && "$dest/work" hosts self "$self"
if [ "$discover" = 1 ]; then
  "$dest/work" hosts discover || printf 'install.sh: registro nao preenchido automaticamente (sem tailscale?); use `work hosts add`\n' >&2
fi

case ":$orig_path:" in
  *":$dest:"*) ;;
  *) printf '\nATENCAO: %s nao esta no PATH do seu shell.\n' "$dest" ;;
esac

printf '\npronto. teste com: work doctor\n'
