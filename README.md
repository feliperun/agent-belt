# tmux work sessions

Sessões de trabalho persistentes: cada tarefa ganha um **git worktree** isolado,
uma **sessão tmux** e um **Claude Code** rodando lá dentro. Fechar o terminal,
cair a conexão ou desconectar o RDP não mata nada — `work <tarefa>` de novo reata.

Funciona em três papéis:

| diretório | papel |
|---|---|
| `mac/` | macOS (zsh) — host de sessões |
| `windows/` | Windows 11 (PowerShell 5.1 + MSYS2) — host de sessões |
| `client/` | qualquer terminal remoto (Linux/macOS) — só dispara e reata nos hosts |

## Uso

Num host, dentro de um repo git:

```
work <tarefa>          # cria worktree irmão + sessão tmux + claude; reata se existir
tm [nome]              # sessão tmux simples (reata ou cria)
works                  # (Windows) lista as sessões vivas
```

`work xpto` em `~/dev/micromed/coreum` cria o worktree `coreum-xpto` na branch
`work/xpto` e a sessão tmux `coreum-xpto`.

De um terminal remoto:

```
rwork <tarefa> [repo]        # alvo default (mac)
rwork mac <tarefa> [repo]    # host macOS
rwork win <tarefa> [repo]    # host Windows
rwork [mac|win] ls           # sessões vivas no alvo
rwork doctor                 # testa ssh + work-session nos dois alvos
```

## Instalação

**macOS** — `mac/work-session` em `~/.local/bin/` (`chmod +x`), e o conteúdo de
`mac/zshrc-snippet.sh` no `~/.zshrc`.

**Windows** — precisa de MSYS2 com tmux e winpty, Git for Windows, Node e o
`claude.exe`:

```powershell
winget install --id MSYS2.MSYS2 -e
C:\msys64\usr\bin\bash.exe -lc "pacman -Sy --noconfirm --needed tmux winpty"
```

Depois `windows/work-session` em `%USERPROFILE%\.local\bin\` (line endings **LF**)
e `windows/Microsoft.PowerShell_profile.ps1` em
`%USERPROFILE%\Documents\WindowsPowerShell\`.

**Cliente remoto** — `client/rwork-snippet.sh` em `~/.local/bin/` e um
`. ~/.local/bin/rwork-snippet.sh` no `~/.bashrc` (ou `.zshrc`). Hosts e usuários
saem de `RWORK_MAC_HOST`, `RWORK_MAC_USER`, `RWORK_WIN_HOST`, `RWORK_WIN_USER`;
o alvo default de `RWORK_TARGET`.

## Por que o Windows é diferente

Não é WSL de propósito: numa máquina com virtualização desligada e repos
Windows-nativos em `C:\dev`, o acesso por `/mnt/c` seria lento e sem toolchain.
O multiplexador é o tmux do MSYS2 e o `claude.exe` continua nativo. Isso impõe
quatro adaptações, todas comentadas no `windows/work-session`:

1. **`winpty` na frente do `claude.exe`** — sem ele o Node não acha um console de
   verdade dentro do pane e a TUI não entra em raw mode.
2. **PATH montado à mão** — o login shell do MSYS2 é mínimo e não vê `git`,
   `node` nem `claude`.
3. **Guarda de colisão** — `$repo-$task` pode bater num repo vizinho real
   (`coreum` → `coreum-docs` existe). Diretório preexistente só é reaproveitado
   se for mesmo worktree daquele repo.
4. **Pré-autorização do worktree** em `~/.claude.json`
   (`hasTrustDialogAccepted`) — sem isso toda sessão nova para no diálogo
   "is this a project you trust?" e a sessão autônoma não sai do lugar.
   `WORK_NO_AUTOTRUST=1` desliga.

## Armadilhas conhecidas

- **PowerShell 5.1 mangleia aspas duplas** ao passar argumento para binário
  nativo. Nada de `"` dentro de string passada ao `bash -lc`.
- **O sshd do Windows embrulha o comando em `powershell -c`**, então quoting de
  shell não vale e aspas aninhadas se perdem. Por isso o `rwork` **valida** os
  argumentos como slug em vez de escapá-los — e barra invertida é recusada:
  use `coreum` ou `C:/dev/coreum`, nunca `C:\dev\coreum`.
- **Conta administradora no Windows**: o `sshd_config` tem
  `Match Group administrators` apontando para
  `C:\ProgramData\ssh\administrators_authorized_keys`. O `~/.ssh/authorized_keys`
  do usuário é **ignorado**, então `ssh-copy-id` falha em silêncio. Escreva no
  arquivo do ProgramData mantendo a ACL restrita a SYSTEM + Administradores.
