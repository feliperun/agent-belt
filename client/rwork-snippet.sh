
# --- rwork: atacha ou inicia uma sessao de trabalho numa maquina remota ---
# rwork <tarefa> [repo]         -> alvo default ($RWORK_TARGET, ou mac)
# rwork mac <tarefa> [repo]     -> frb@macbook-pro      (repos em ~/dev/micromed)
# rwork win <tarefa> [repo]     -> Micromed@felipe-windows (repos em C:\dev)
# rwork [mac|win] ls            -> lista as sessoes vivas no alvo
# rwork doctor                  -> testa o ssh e o work-session nos dois alvos
#
# A logica roda no alvo, em work-session. A diferenca entre os alvos nao e so o
# host: no mac o sshd entrega o comando ao zsh, e no windows ele embrulha em
# `powershell -c`, onde quoting de shell nao vale nada e aspas aninhadas sao
# mangleadas. Por isso os argumentos aqui sao *validados* como tokens simples em
# vez de escapados -- nome de tarefa vira branch git e sessao tmux, entao slug e
# o unico formato que faz sentido nos dois lados de qualquer jeito.
#
# Tarefa chamada "mac" ou "win" seria engolida como alvo: escreva o alvo
# explicito, ex. `rwork win win`.
rwork() {
  local target="${RWORK_TARGET:-mac}"

  if [ "${1:-}" = "doctor" ]; then
    local t
    for t in mac win; do
      printf '== %s ==\n' "$t"
      RWORK_TARGET="$t" rwork "$t" ls || printf '   FALHOU: veja se a chave desta maquina esta no authorized_keys do alvo\n'
    done
    return 0
  fi

  case "${1:-}" in
    mac|win) target="$1"; shift ;;
  esac

  local host user
  case "$target" in
    mac) host="${RWORK_MAC_HOST:-macbook-pro}";    user="${RWORK_MAC_USER:-frb}" ;;
    win) host="${RWORK_WIN_HOST:-felipe-windows}"; user="${RWORK_WIN_USER:-Micromed}" ;;
    *)   printf 'rwork: alvo desconhecido %s (use mac ou win)\n' "$target" >&2; return 1 ;;
  esac

  if [ "${1:-}" = "ls" ]; then
    case "$target" in
      # No windows o `works` e uma funcao do profile do PowerShell: um unico
      # token, sem aspas para o sshd mangleiar.
      mac) ssh "${user}@${host}" 'tmux ls 2>/dev/null || echo nenhuma-sessao-viva' ;;
      win) ssh "${user}@${host}" works ;;
    esac
    return $?
  fi

  local task="${1:-}" repo="${2:-}"
  if [ -z "$task" ]; then
    printf 'usage: rwork [mac|win] <tarefa> [repo]\n       rwork [mac|win] ls\n       rwork doctor\n' >&2
    return 1
  fi

  case "$task" in
    *[!A-Za-z0-9._-]*)
      printf 'rwork: nome de tarefa deve ser slug [A-Za-z0-9._-]: %s\n' "$task" >&2; return 1 ;;
  esac
  if [ -n "$repo" ]; then
    # Barra invertida fica de fora de proposito: C:\dev\x atravessando o
    # powershell e fonte de bug. Use o nome (coreum) ou C:/dev/coreum.
    case "$repo" in
      *[!A-Za-z0-9._/:~-]*)
        printf 'rwork: repo com caractere inseguro (use nome, /c/dev/x ou C:/dev/x): %s\n' "$repo" >&2; return 1 ;;
    esac
  fi

  case "$target" in
    mac) ssh -t "${user}@${host}" "~/.local/bin/work-session $task $repo" ;;
    win) ssh -t "${user}@${host}" "C:\\msys64\\usr\\bin\\bash.exe -l /c/Users/Micromed/.local/bin/work-session $task $repo" ;;
  esac
}
