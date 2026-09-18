# --- helpers de sessao persistente: tmux + claude (porte do .zshrc do mac) ---
# O multiplexador e o tmux do MSYS2; o claude continua sendo o .exe nativo.
# A logica de verdade vive em ~/.local/bin/work-session, chamado tambem via ssh.

$MsysBash = 'C:\msys64\usr\bin\bash.exe'

function Get-WorkSessionScript {
    # Cygwin abre "C:/Users/..." sem problema; barra invertida ele mangleia.
    ($env:USERPROFILE -replace '\\', '/') + '/.local/bin/work-session'
}

# work nome-da-tarefa [repo]
#   Dentro de um repo git, cria um worktree irmao (fora do repo principal), uma
#   sessao tmux e sobe o claude la dentro; reata se a sessao ja existir.
function work {
    param(
        [Parameter(Position = 0, Mandatory = $true)][string] $Task,
        [Parameter(Position = 1)][string] $Repo
    )

    if (-not $Repo) {
        $top = & git rev-parse --show-toplevel 2>$null
        if ($LASTEXITCODE -eq 0 -and $top) { $Repo = @($top)[0] }
    }

    $argv = @((Get-WorkSessionScript), $Task)
    if ($Repo) { $argv += $Repo }
    & $MsysBash -l @argv
}

# tm nome -> reata a sessao se existir, cria se nao existir
function tm {
    param([Parameter(Position = 0)][string] $Name = 'main')
    if ($Name -notmatch '^[\w.-]+$') { Write-Error "nome de sessao invalido: $Name"; return }
    # Sob ConPTY o TERM pode chegar vazio, e aí o tmux se recusa a desenhar.
    & $MsysBash -lc "export TERM=`${TERM:-xterm-256color}; exec tmux new -A -s $Name"
}

# works -> lista as sessoes vivas (o que sobreviveu ao ultimo desconectar)
function works {
    # Sem aspas duplas na string: o PowerShell 5.1 as mangleia ao passar
    # argumento para binario nativo, e o tmux recebia -F sem valor.
    & $MsysBash -lc 'tmux ls 2>/dev/null || echo nenhuma-sessao-viva'
}
