# --- sessoes de trabalho persistentes: tmux + agente (claude/codex) ---
# O multiplexador e o tmux do MSYS2; os agentes continuam sendo .exe nativos.
# Toda a logica vive em ~/.local/bin/work, o mesmo script do mac e do Linux.
#
# Nada de aspas duplas nas strings passadas ao bash: o PowerShell 5.1 as
# mangleia ao entregar argumento para binario nativo.

$MsysBash = 'C:\msys64\usr\bin\bash.exe'

function Get-WorkScript {
    # Cygwin abre "C:/Users/..." sem problema; barra invertida ele mangleia.
    ($env:USERPROFILE -replace '\\', '/') + '/.local/bin/work'
}

# work                            menu interativo com as sessoes de todas as maquinas
# work ls                         a mesma lista, em texto
# work <tarefa> [repo]            cria (ou reata) aqui
# work <maquina> <tarefa> [repo]  cria (ou reata) na maquina do tailnet
# work attach <sessao> [maquina]  atacha direto
# work doctor | work hosts        diagnostico e registro de maquinas
function work {
    $argv = @((Get-WorkScript)) + $args
    & $MsysBash -l @argv
}

# Nome antigo, mesmo programa.
function rwork { work @args }

# works -> as sessoes vivas de todas as maquinas (o que sobreviveu ao desconectar)
function works { work ls }

# tm nome -> reata a sessao se existir, cria se nao existir
function tm {
    param([Parameter(Position = 0)][string] $Name = 'main')
    if ($Name -notmatch '^[\w.-]+$') { Write-Error "nome de sessao invalido: $Name"; return }
    # Sob ConPTY o TERM pode chegar vazio, e ai o tmux se recusa a desenhar.
    & $MsysBash -lc "export TERM=`${TERM:-xterm-256color}; exec tmux new -A -s $Name"
}
