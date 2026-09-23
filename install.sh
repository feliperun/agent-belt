#!/usr/bin/env bash
# install.sh [--keep-config] | --uninstall
#
# Instala o minikeyboard como app de background: compila, empacota em
# ~/Applications/Minikeyboard.app, assina, guarda a chave do Deepgram no
# Keychain e registra um LaunchAgent que sobe no login e renasce se cair.
#
# A configuracao vem do codigo (src/config.zig): cada instalacao regenera
# ~/.config/minikeyboard/config.json a partir dos padroes. --keep-config
# preserva o arquivo atual.

set -euo pipefail

label=com.frb.minikeyboard
app="$HOME/Applications/Minikeyboard.app"
exe="$app/Contents/MacOS/minikeyboard"
plist="$HOME/Library/LaunchAgents/$label.plist"
log="$HOME/Library/Logs/minikeyboard.log"
link="$HOME/.local/bin/minikeyboard"
domain="gui/$(id -u)"
src=$(cd "$(dirname "$0")" && pwd)

say() { printf '\033[1m==>\033[0m %s\n' "$*"; }
die() { printf 'install.sh: %s\n' "$*" >&2; exit 1; }

# Para o LaunchAgent e qualquer daemon aberto a mao num terminal: dois
# daemons dobrariam cada tecla.
stop_daemons() {
  launchctl bootout "$domain/$label" 2>/dev/null || true
  pkill -f '/minikeyboard daemon$' 2>/dev/null || true
  for _ in $(seq 1 50); do
    pgrep -f '/minikeyboard daemon$' >/dev/null || return 0
    sleep 0.1
  done
  pkill -9 -f '/minikeyboard daemon$' 2>/dev/null || true
}

keep_config=0
case "${1:-}" in
  --uninstall)
    say "removendo LaunchAgent, app e link"
    stop_daemons
    rm -f "$plist" "$link"
    rm -rf "$app"
    say "pronto. Config (~/.config/minikeyboard) e chave no Keychain foram mantidas;"
    printf '    para apagar a chave: security delete-generic-password -s minikeyboard -a deepgram\n'
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

version=$(git -C "$src" describe --always --dirty 2>/dev/null || echo dev)
stage=$(mktemp -d)/Minikeyboard.app
mkdir -p "$stage/Contents/MacOS"
cp "$src/zig-out/bin/minikeyboard" "$stage/Contents/MacOS/minikeyboard"
cat > "$stage/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>$label</string>
  <key>CFBundleName</key><string>Minikeyboard</string>
  <key>CFBundleExecutable</key><string>minikeyboard</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$version</string>
  <key>CFBundleVersion</key><string>$version</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>O minikeyboard grava sua voz enquanto a tecla de push-to-talk esta pressionada para transcrever com o Deepgram.</string>
</dict></plist>
PLIST

# As permissoes (Monitoramento de Entrada, Acessibilidade, Microfone) ficam
# presas a assinatura. Com um certificado, o requisito e "este bundle id +
# este certificado" e sobrevive a cada rebuild; ad-hoc muda a cada build.
identity="${MINIKEYBOARD_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null |
  sed -n 's/.*"\(Apple Development: [^"]*\)".*/\1/p' | head -1)}"
if [ -z "$identity" ]; then
  identity=-
  say "sem certificado de assinatura: usando ad-hoc (as permissoes precisarao ser dadas de novo a cada atualizacao)"
fi
say "assinando com: $identity"
codesign --force --sign "$identity" --identifier "$label" "$stage" >/dev/null

say "parando daemons em execucao"
stop_daemons
mkdir -p "$(dirname "$app")"
rm -rf "$app"
mv "$stage" "$app"

mkdir -p "$(dirname "$link")"
ln -sf "$exe" "$link"

if [ "$keep_config" = 0 ]; then
  say "config regenerada a partir de src/config.zig"
  "$exe" init >/dev/null 2>&1
fi

# O LaunchAgent nao herda o ambiente do shell: a chave vai para o Keychain,
# liberada para o app sem prompt.
# So grava quando falta (ou com MINIKEYBOARD_UPDATE_KEY=1): alterar um item
# existente abre um dialogo do Keychain e travaria a instalacao.
if security find-generic-password -s minikeyboard -a deepgram >/dev/null 2>&1 &&
    [ "${MINIKEYBOARD_UPDATE_KEY:-0}" != 1 ]; then
  say "chave do Deepgram ja esta no Keychain"
elif [ -n "${DEEPGRAM_API_KEY:-}" ]; then
  say "guardando DEEPGRAM_API_KEY no Keychain"
  security delete-generic-password -s minikeyboard -a deepgram >/dev/null 2>&1 || true
  security add-generic-password -s minikeyboard -a deepgram -w "$DEEPGRAM_API_KEY" -T "$app" >/dev/null
else
  if [ -t 0 ]; then
    read -rsp "Chave do Deepgram: " key; echo
    [ -n "$key" ] && security add-generic-password -U -s minikeyboard -a deepgram -w "$key" -T "$app" >/dev/null
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

Na primeira vez, autorize "Minikeyboard" em Ajustes do Sistema >
Privacidade e Seguranca: Monitoramento de Entrada e Acessibilidade (o daemon tenta
de novo sozinho a cada ~15 s) e o Microfone no primeiro push-to-talk.

  minikeyboard agents list        CLI (link em $link)
  tail -f $log
  ./install.sh --uninstall
MSG
