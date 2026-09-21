# work — sessões de trabalho persistentes no tailnet inteiro

Cada tarefa ganha um **git worktree** isolado, uma **sessão tmux** e um **agente**
(Claude Code ou Codex) rodando lá dentro. Fechar o terminal, cair a conexão ou
desconectar o RDP não mata nada — `work` de novo reata.

A sessão pode nascer em **qualquer máquina do tailnet, a partir de qualquer
outra**, e a lista de sessões vivas é sempre a lista de *todas* as máquinas,
independente de onde você está e de que diretório.

```
work                            menu interativo com as sessões de todas as máquinas
work ls                         a mesma lista, em texto
work <tarefa> [repo]            cria (ou reata) aqui
work <máquina> <tarefa> [repo]  cria (ou reata) na máquina do tailnet
work attach <sessão> [máquina]  atacha direto, sem menu
work hosts [discover|add|rm|self]   registro de máquinas
work doctor                     testa ssh, work e toolchain em cada máquina

  -a|--agent claude|codex|shell   qual agente sobe (default: claude)
  --codex / --claude / --shell    atalhos
tm [nome]                         sessão tmux simples, sem worktree nem agente
```

`work xpto` dentro de `~/dev/micromed/coreum` cria o worktree `coreum-xpto` na
branch `work/xpto` e a sessão tmux `coreum-xpto`. `work frb-omarchy xpto coreum`
faz o mesmo na omarchy — e se você estiver dentro de um repo git, o **nome** do
repo viaja junto, então `work frb-omarchy xpto` resolve `coreum` na cópia de lá.

Máquinas são identificadas pelo **nome oficial do tailnet** (`macbook-pro`,
`felipe-windows`, `frb-omarchy`, …). Prefixo não-ambíguo também serve:
`work frb-om xpto`.

## Arquitetura

Um script só, `bin/work`, instalado em **todas** as máquinas — cada uma é
cliente e host ao mesmo tempo. Quando o alvo é ela mesma, executa local; quando
é outra, chama por ssh o `work` de lá. Quem cria a sessão é sempre o
`bin/work-session` da máquina de destino, que resolve PATH, worktree, confiança
do agente e tmux com as regras da plataforma dele.

```
bin/work          dispatcher: registro, menu, ls, attach, doctor
bin/work-session  cria/reata a sessão nesta máquina (macOS, Linux, MSYS2)
bin/tm            sessão tmux simples
windows/…ps1      funções work/tm/works do PowerShell (chamam o bash do MSYS2)
install.sh        instala em ~/.local/bin desta máquina
scripts/deploy.sh instala/atualiza nas máquinas do registro
scripts/mesh-keys.sh   distribui as chaves ssh para todo mundo se falar com todo mundo
```

### Registro de máquinas

`~/.config/work/hosts.conf`, uma linha por máquina:

```
host macbook-pro     frb@macbook-pro           posix
host felipe-windows  Micromed@felipe-windows   msys
host frb-omarchy     frb@frb-omarchy           posix
self macbook-pro
```

`work hosts discover` preenche isso a partir do `tailscale status` (o usuário
ssh sai do `~/.ssh/config` de cada host, e o tipo, do SO informado pelo
tailnet). O `deploy.sh` **copia** esse registro para as outras máquinas em vez
de redescobrir lá: redescobrir do outro lado erra o usuário de quem não está no
`~/.ssh/config` de lá — `Micromed@felipe-windows` viraria `frb@felipe-windows`.

## Instalação

**Numa máquina** (macOS, Linux ou Windows com MSYS2):

```
./install.sh
```

Copia `work`, `work-session` e `tm` para `~/.local/bin` (mais o apelido `rwork`),
descobre as máquinas do tailnet e marca qual é esta. No Windows instala também o
profile do PowerShell.

**Nas outras, a partir de uma já instalada:**

```
./scripts/deploy.sh --all          # ou: ./scripts/deploy.sh frb-omarchy felipe-windows
```

**Chaves ssh de todos para todos** (o que permite criar sessão em qualquer
combinação de origem e destino):

```
./scripts/mesh-keys.sh --dry-run   # mostra o que faria + a matriz de quem alcança quem
./scripts/mesh-keys.sh             # corrige e mostra a matriz
```

Ele cuida dos **dois** motivos que derrubam um par:

1. `authorized_keys` sem a chave da origem → `Permission denied (publickey)`.
   Quais chaves distribuir não se descobre listando `~/.ssh/*.pub`: o
   `~/.ssh/config` pode forçar uma `IdentityFile` diferente por destino. Quem
   sabe a resposta é o ssh da origem, então o script roda
   `ssh -G <destino>` lá e usa exatamente o que ele diz que vai oferecer.
2. `known_hosts` com host key antiga → `HOST IDENTIFICATION HAS CHANGED`, que
   recusa a conexão *antes* de autenticar. Acontece quando uma máquina é
   reinstalada. A referência é o `known_hosts` de quem roda o script (que
   alcança todas); só na falta de registro local a chave vem do `ssh-keyscan`.

Máquina fora do ar é simplesmente pulada — rode de novo quando ela voltar.

O Windows fica de fora da escrita automática: lá a conta é administradora e o
sshd usa `C:\ProgramData\ssh\administrators_authorized_keys`, com ACL restrita a
SYSTEM + Administradores — `ssh-copy-id` acerta o arquivo errado e falha em
silêncio. Como o Windows já aceita as outras máquinas, o script só reporta.

**Windows, pré-requisitos** — MSYS2 com tmux e winpty, Git for Windows, Node e
o `claude.exe`:

```powershell
winget install --id MSYS2.MSYS2 -e
C:\msys64\usr\bin\bash.exe -lc "pacman -Sy --noconfirm --needed tmux winpty"
```

## Agentes

| agente | como sobe |
|---|---|
| `claude` (default) | `claude --dangerously-skip-permissions --name <tarefa>` |
| `codex` | `codex --dangerously-bypass-approvals-and-sandbox` |
| `shell` | só o `$SHELL` no worktree, sem agente |

Os dois param num diálogo de confiança ao abrir um diretório novo — e todo
worktree é um diretório novo, o que mataria a sessão autônoma antes de começar.
Como o worktree é um checkout do repo que você mesmo escolheu, o `work-session`
pré-autoriza: `hasTrustDialogAccepted` no `~/.claude.json` para o Claude,
`[projects."<caminho>"] trust_level = "trusted"` no `config.toml` do Codex
(respeitando `CODEX_HOME`). `WORK_NO_AUTOTRUST=1` desliga.

O agente escolhido fica marcado na sessão (`@work_agent`) e aparece na coluna
AGENTE do `work ls`. Sessão que **não** nasceu pelo `work` — inclusive um tmux
que você abriu na mão — também aparece na lista, com o agente deduzido do
processo em primeiro plano do pane e um `~` indicando que é dedução.

### O que a lista diz além das sessões

```
5 maquinas: 1 com sessao, 4 sem, 1 sem resposta: frb-linux  ->  work doctor
agente fora do tmux, aberto direto (nao da para atachar): felipe-windows (1)
```

Sem esse rodapé não dá para distinguir "essa máquina não tem sessão" de "essa
máquina não respondeu" — e você fica procurando uma sessão que a lista nunca
vai mostrar. A resposta do `ls-raw` termina numa linha `#fora`, que serve de
sinal de vida: se ela não chegou, a máquina entra como *sem resposta*.

**Agente aberto direto, fora do tmux, não tem como ser atachado.** Um processo
de console não migra para dentro do tmux depois de começar: no Linux existe o
`reptyr`, frágil com TUI, e no Windows não há equivalente — o processo está
preso ao ConPTY da janela que o criou, e o caminho de volta é o RDP naquela
sessão. Por isso o `work` só conta e avisa. Para ser atacável, tem que nascer
dentro do tmux (`work <tarefa>`, ou `tm` para uma sessão simples).

## Por que o Windows é diferente

Não é WSL de propósito: numa máquina com virtualização desligada e repos
Windows-nativos em `C:\dev`, o acesso por `/mnt/c` seria lento e sem toolchain.
O multiplexador é o tmux do MSYS2 e o agente continua nativo. Daí quatro
adaptações, todas comentadas no código:

1. **`winpty` na frente do agente** — sem ele o Node não acha um console de
   verdade dentro do pane e a TUI não entra em raw mode.
2. **PATH montado à mão** — o login shell do MSYS2 é mínimo e não vê `git`,
   `node` nem `claude`.
3. **Guarda de colisão** — `$repo-$task` pode bater num repo vizinho real
   (`coreum` → `coreum-docs` existe). Diretório preexistente só é reaproveitado
   se for mesmo worktree daquele repo. Vale em todas as plataformas.
4. **Pré-autorização do worktree**, acima.

## Armadilhas conhecidas

- **O sshd do Windows embrulha o comando em `powershell -c`.** Quoting de shell
  não vale nada ali: aspas duplas somem, `\ ` não escapa espaço, `||` vira erro
  de sintaxe. Por isso o `work` manda para lá só tokens simples (e valida os
  argumentos como slug em vez de escapá-los), o `deploy.sh` usa PowerShell puro
  sem aspas para criar diretório, e o `mesh-keys.sh` manda script por **stdin**
  (`bash -l -s`) quando precisa de aspas.
- **`bash -s` sem `-l` no MSYS2** não tem nem `/usr/bin` no PATH: `uname`, `tr`
  e `head` somem. Sempre `-l -s`.
- **Barra invertida é recusada nos argumentos**: use `coreum` ou
  `C:/dev/coreum`, nunca `C:\dev\coreum`.
- **Nada de caractere de controle em formato do tmux.** O `ls-raw` separa campos
  com `|`: sob locale C o tmux troca não-imprimível por `_` na saída do `-F`, e
  só no destino remoto — o campo some e a linha inteira desalinha.
- **Tab também não serve como separador**: o `read` do bash colapsa sequências
  de espaço em branco, e um campo vazio desloca todos os outros.
- **`tmux set-option -t` não aceita o prefixo `=`** de alvo exato (mas
  `attach`/`has-session` aceitam), e um `-s` no lugar viraria *server option* —
  marcaria todas as sessões de uma vez.
- **Função de shell sombreia o PATH**: `work` e `tm` eram funções no `.zshrc`;
  viraram scripts justamente para valerem igual em toda máquina.
- **`bash -s` lendo script por stdin também serve para mandar dados**: o
  `while read` depois do `done` consome o resto do mesmo stdin. É como o
  `mesh-keys.sh` entrega script *e* lista para o Windows, onde argumento com
  aspas não sobrevive ao `powershell -c`.
- **Saída do PowerShell vem com CRLF**: `grep -x OK` falha silenciosamente sem
  um `tr -d '\r'` antes — dá falso-negativo em teste de conectividade.
- **`IdentitiesOnly yes` com lista fixa de `Host` não cobre máquina nova.** No
  Windows o bloco tailnet do `~/.ssh/config` aponta para uma chave sem
  passphrase; um host fora dessa lista cai na `id_ed25519` padrão, que *tem*
  passphrase e não abre em `BatchMode` — `Permission denied (publickey)` mesmo
  com a chave certa autorizada no destino. Ao registrar uma máquina nova,
  acrescente o nome dela nesse `Host`.
- **O `ssh` do Windows não está no PATH do login shell do MSYS2**
  (`/c/Windows/System32/OpenSSH`). Sem isso a máquina funciona como host mas
  não como cliente: as chamadas remotas falham caladas e o `work ls` mostra só
  as sessões locais.
