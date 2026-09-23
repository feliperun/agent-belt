#!/usr/bin/env bash
# install.sh [--keep-config] | --uninstall | --package <dir>
#
# Instala o agent-belt como app de background: compila, empacota em
# ~/Applications/Agent Belt.app, assina, guarda a chave do Deepgram no
# Keychain e registra um LaunchAgent que sobe no login e renasce se cair.
#
# A configuracao vem do codigo (src/config.zig): cada instalacao regenera
# ~/.config/agent-belt/config.json a partir dos padroes. --keep-config
# preserva o arquivo atual.

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

# Para o LaunchAgent e qualquer daemon aberto a mao num terminal: dois
# daemons dobrariam cada tecla.
stop_daemons() {
  launchctl bootout "$domain/$label" 2>/dev/null || true
  launchctl bootout "$domain/com.frb.minikeyboard" 2>/dev/null || true # before the rename
  pkill -f '/minikeyboard daemon$' 2>/dev/null || true
  pkill -f '/agent-belt daemon$' 2>/dev/null || true
  pkill -f '/agb daemon$' 2>/dev/null || true
  for _ in $(seq 1 50); do
    pgrep -f '/(agb|agent-belt) daemon$' >/dev/null || return 0
    sleep 0.1
  done
  pkill -9 -f '/(agb|agent-belt) daemon$' 2>/dev/null || true
}

keep_config=0
package=""
case "${1:-}" in
  --package) package="${2:?install.sh: --package precisa de um diretorio}" ;;
  --uninstall)
    say "removendo LaunchAgent, app e link"
    stop_daemons
    rm -f "$plist" "$link" "$HOME/.local/bin/agent-belt"
    rm -rf "$app"
    say "pronto. Config (~/.config/agent-belt) e chave no Keychain foram mantidas;"
    printf '    para apagar a chave: security delete-generic-password -s agent-belt -a deepgram\n'
    exit 0 ;;
  --keep-config) keep_config=1 ;;
  "") ;;
  -h|--help) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) die "opcao desconhecida: $1" ;;
esac

[ "$(uname -s)" = Darwin ] || die "so roda no macOS"
command -v zig >/dev/null || die "zig nao encontrado (brew install zig)"

say "compilando (ReleaseSafe)"
(cd "$src" && zig build -Doptimize=ReleaseSafe)

version=$(tr -d " \n" < "$src/version.txt")
stage="$(mktemp -d)/Agent Belt.app"
mkdir -p "$stage/Contents/MacOS" "$stage/Contents/Resources"
cp "$src/assets/AppIcon.icns" "$stage/Contents/Resources/AppIcon.icns"
cp "$src/scripts/update.sh" "$stage/Contents/Resources/update.sh"
# The work engine behind agb sessions/new/ls/attach/tm/deploy.
rsync -a --exclude .claude "$src/work/" "$stage/Contents/Resources/work/"
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

# As permissoes (Monitoramento de Entrada, Acessibilidade, Microfone) ficam
# presas a assinatura. Com um certificado, o requisito e "este bundle id +
# este certificado" e sobrevive a cada rebuild; ad-hoc muda a cada build.
identity="${AGENT_BELT_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null |
  sed -n 's/.*"\(Apple Development: [^"]*\)".*/\1/p' | head -1)}"
if [ -z "$identity" ]; then
  identity=-
  say "sem certificado de assinatura: usando ad-hoc (as permissoes precisarao ser dadas de novo a cada atualizacao)"
fi
say "assinando com: $identity"
codesign --force --sign "$identity" --identifier "$label" "$stage" >/dev/null

# --package: just the signed app, zipped (used by the release workflow).
if [ -n "$package" ]; then
  mkdir -p "$package"
  zip="$(cd "$package" && pwd)/Agent-Belt-$version-macos.zip"
  (cd "$(dirname "$stage")" && ditto -c -k --keepParent "Agent Belt.app" "$zip")
  say "pacote: $zip"
  exit 0
fi

say "parando daemons em execucao"
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

# work/tm: tmux sessions with an agent inside, on any machine of the tailnet.
say "instalando work, work-session e tm"
"$src/work/install.sh" --no-discover >/dev/null

if [ "$keep_config" = 0 ]; then
  say "config regenerada a partir de src/config.zig"
  "$exe" init >/dev/null 2>&1
fi

# O LaunchAgent nao herda o ambiente do shell: a chave vai para o Keychain,
# liberada para o app sem prompt.
# So grava quando falta (ou com AGENT_BELT_UPDATE_KEY=1): alterar um item
# existente abre um dialogo do Keychain e travaria a instalacao.
if security find-generic-password -s agent-belt -a deepgram >/dev/null 2>&1 &&
    [ "${AGENT_BELT_UPDATE_KEY:-0}" != 1 ]; then
  say "chave do Deepgram ja esta no Keychain"
elif [ -n "${DEEPGRAM_API_KEY:-}" ]; then
  say "guardando DEEPGRAM_API_KEY no Keychain"
  security delete-generic-password -s agent-belt -a deepgram >/dev/null 2>&1 || true
  security add-generic-password -s agent-belt -a deepgram -w "$DEEPGRAM_API_KEY" -T "$app" >/dev/null
else
  if [ -t 0 ]; then
    read -rsp "Chave do Deepgram: " key; echo
    [ -n "$key" ] && security add-generic-password -U -s agent-belt -a deepgram -w "$key" -T "$app" >/dev/null
  else
    say "sem chave do Deepgram: o push-to-talk vai falhar ate rodar de novo com DEEPGRAM_API_KEY"
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

say "iniciando LaunchAgent"
launchctl bootstrap "$domain" "$plist"
launchctl enable "$domain/$label"
launchctl kickstart -k "$domain/$label" >/dev/null

sleep 1
if launchctl print "$domain/$label" 2>/dev/null | grep -q 'state = running'; then
  say "rodando ($version). Log: $log"
else
  say "o LaunchAgent nao esta rodando; veja $log"
fi
cat <<MSG

Na primeira vez, autorize "Agent Belt" em Ajustes do Sistema >
Privacidade e Seguranca: Monitoramento de Entrada e Acessibilidade (o daemon tenta
de novo sozinho a cada ~15 s) e o Microfone no primeiro push-to-talk.

  agb agents list               CLI (link em $link)
  tail -f $log
  ./install.sh --uninstall
MSG
