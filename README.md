<p align="center">
  <img src="assets/icon-256.png" width="128" alt="Agent Belt">
</p>

<h1 align="center">Agent Belt</h1>

<p align="center">
  O cinto de utilidades de quem trabalha com coding agents 🦇<br>
  Um macropad de 6 teclas + knob vira ditado por voz, troca entre agentes, luzes de aviso e atalhos para o Claude Code e o Codex, no macOS.
</p>

<p align="center">
  <a href="https://github.com/feliperun/agent-belt/actions/workflows/ci.yml"><img src="https://github.com/feliperun/agent-belt/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <a href="https://github.com/feliperun/agent-belt/releases/latest"><img src="https://img.shields.io/github/v/release/feliperun/agent-belt" alt="Release"></a>
</p>

<p align="center">
  <img src="assets/overlay.gif" width="560" alt="Overlay ouvindo a voz e decifrando a transcrição">
</p>

## O que tem no cinto

| Gadget | O que faz |
|---|---|
| 🎙️ **Ditado** | Segure a tecla, fale, solte: o Deepgram transcreve e o texto aparece onde está o cursor. |
| 🔀 **Troca de agentes** | Um toque vai para o próximo agente, primeiro para quem espera uma decisão sua ou acabou de terminar. |
| 📋 **Menu de agentes** | Todos os agentes, com estado, recap, tempo, custo, tokens e as cotas do Claude e do Codex. |
| 🦇 **Novo agente por voz** | *"Crie um agente no Windows com Codex no coreum para investigar o login"*: abre a sessão pronta, em qualquer máquina do tailnet. |
| 🚨 **Sinal** | As teclas acendem vermelho quando um agente aguarda você e verde quando um termina; longe do Mac, chega um aviso no WhatsApp. |
| 🎛️ **Knob** | Girar rola a página; apertar leva todos os agentes de volta ao fim da saída. |
| ⌨️ **Sem o tecladinho** | Atalhos no teclado do Mac e um menu na barra de menus fazem tudo o que o macropad faz. |

## As teclas

```
┌──────┬──────┬──────┐   ╭────╮
│  0   │  1   │  2   │   │knob│  girar: rolar · apertar: agentes de volta ao fim
│ Esc  │ menu │Delete│   ╰────╯
├──────┼──────┼──────┤
│  3   │  4   │  5   │
│ fala │agente│Return│
└──────┴──────┴──────┘
```

- **3, segurar:** ditado (com o menu de agentes aberto, vira um comando de voz).
- **4:** próximo agente, priorizando quem aguarda você.
- **1:** menu de agentes. Toque navega, duplo toque abre.
- **0, 2, 5:** Esc, Delete e Return, que repetem ao segurar.

## Instalação

Precisa de macOS 14+, Xcode Command Line Tools, `zig` (`brew install zig`) e uma chave do
[Deepgram](https://deepgram.com).

```sh
export DEEPGRAM_API_KEY=...
curl -fsSL https://raw.githubusercontent.com/feliperun/agent-belt/main/scripts/update.sh | bash
```

O comando baixa a última release e roda o `./install.sh` dela. De um clone do repositório,
basta rodar `./install.sh`. O instalador:

- compila e monta `~/Applications/Agent Belt.app`, assinado com o seu certificado Apple
  Development quando houver um, o que faz as permissões sobreviverem às atualizações;
- guarda a chave do Deepgram no Keychain;
- registra o LaunchAgent `com.frb.agentbelt`, que sobe no login e reinicia se cair;
- instala a CLI `agb` e as ferramentas `work`, `work-session` e `tm` em `~/.local/bin`.

Na primeira vez, autorize **Agent Belt** em
[Monitoramento de Entrada](x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent) e
[Acessibilidade](x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility).
O [Microfone](x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone) é pedido no primeiro
ditado. O daemon abre sozinho a lista que faltar, e `agb permissions` abre as três.
`agb status` confirma se está tudo certo.

## Agentes

<p align="center">
  <img src="assets/menu.png" width="440" alt="Menu de agentes">
</p>

O Agent Belt enxerga os agentes que estão rodando em terminais do Orca
e em sessões tmux do `work`, esteja o tmux dentro do Orca ou em outro terminal. Para cada
um, ele mostra:

- **Estado:** 🔴 aguardando uma decisão sua (prompt de aprovação na tela), 🟢 terminou e
  você ainda não viu, 🔵 trabalhando, ⚪ ocioso.
- **Título e recap:** o título que o próprio Claude Code dá à sessão, e o resumo ou o último
  pedido.
- **Tempo, custo e tokens:** somados dos transcripts, incluindo subagentes, pelo preço de
  lista.
- **Cotas:** janela de 5 h e semanal do Claude e do Codex.

Os detalhes e as fontes de cada dado estão em [docs/agent-stats.md](docs/agent-stats.md).

A tecla 4 e o menu levam ao agente escolhido: trocam a aba no Orca, restauram a janela se
estiver minimizada e trazem o app para frente.

### Novo agente por voz

Com o menu aberto, segure a tecla de fala e peça. Um Claude Haiku (`claude -p`, com a sua
conta) entende máquina, agente, repositório e tarefa. Em seguida, um terminal novo no Orca
roda o `work` com a instrução como primeiro prompt. O mesmo funciona pelo terminal, e
também para outro agente:

```sh
agb new --dry-run crie um agente no windows com codex no coreum para investigar o login
# work felipe-windows investigar-login coreum --agent codex --prompt 'Investigue…'
```

## Luzes

| Estado | Teclas |
|---|---|
| gravando | branco fixo |
| transcrevendo | ciano fixo |
| um agente aguarda você | **vermelho** |
| um agente terminou | **verde** |
| nada pendente | escuras, com uma onda branca a cada toque |

O protocolo dos LEDs foi obtido por engenharia reversa do configurador do fabricante; está em
[docs/led-protocol.md](docs/led-protocol.md). Para trocar à mão: `agb led <cor> <modo>`.

## Sem o tecladinho

| Atalho | Ação |
|---|---|
| `⌃⌥Espaço` | menu de agentes; repetir navega, `↩` abre, `Esc` fecha, `↑` `↓` movem |
| `⌃⌥↑` | próximo agente |
| `⌃⌥↓` | agentes de volta ao fim |

Na barra de menus, a fivela ganha 🔴, 🟢, 🎙️ ou ⏳ conforme o estado, e um clique abre o
menu de agentes com linhas clicáveis. Se um agente espera por você há 3 minutos e o Mac está
parado, um aviso vai para o WhatsApp via `ford-send`.

## Configuração

A configuração vive no código: os padrões ficam em [`src/config.zig`](src/config.zig), e
`./install.sh` regenera `~/.config/agent-belt/config.json` a partir deles (`--keep-config`
preserva o arquivo). Também dá para mudar na hora:

```sh
agb bind 0 key escape            # teclas: escape, delete, return, tab, shift+tab, cmd+k, a-z, 0-9…
agb bind 3 ptt                   # push-to-talk
agb bind 4 agents                # próximo agente (agents desktop inclui Codex/Claude Desktop)
agb bind 1 menu                  # menu de agentes
agb bind 2 command 'open -a Calculator'
agb bind 5 text 'Olá!'
```

Knob e LEDs: `"knob": "scroll"` ou `"system"` (volume), `"knob_scroll_lines": 3` (negativo
inverte o sentido) e `"led": true`.

## CLI

```
agb status                      daemon, permissões, dispositivo, chave, log
agb agents list|next|bottom     agentes com estado e stats · próximo · voltar ao fim
agb new [--dry-run] <pedido>    cria um agente a partir de linguagem natural
agb led <cor 0-7> <modo 0-5>    luzes à mão
agb permissions                 abre as listas de privacidade do macOS
agb version · agb update [tag]  versão · atualizar agora
agb preview                     mostra a animação do ditado sem microfone
```

## Atualizações

A cada 6 h o Agent Belt consulta as releases no GitHub. Quando há uma versão nova, aparece
uma notificação com as notas e o botão **Atualizar**, e o rodapé do menu avisa. O
`agb update` faz o mesmo na hora. A atualização compila a release a partir do código e
assina localmente, então as permissões continuam valendo.

As versões saem pelo [release-please](https://github.com/googleapis/release-please): cada
commit `feat:`/`fix:` entra num PR de release, e o merge publica a tag, o
[CHANGELOG](CHANGELOG.md) e um `.zip` do app.

## work

[`work/`](work/README.md) cria, em qualquer máquina do tailnet, uma sessão tmux com um
worktree e um agente dentro. Fechar o terminal não mata nada: basta rodar `work` de novo
para reanexar.

```sh
work <tarefa> [repo]                          # aqui
work <máquina> <tarefa> [repo] --codex        # em outra máquina
work felipe-windows login coreum --prompt "investigue o login"
```

Para instalar nas outras máquinas: `work/scripts/deploy.sh --all`.

## Como funciona

- **Captura:** um monitor HID sem root lê o macropad (VID `0x514c`, PID `0x8850`). Um
  CGEvent tap engole as letras que ele digitaria e o volume do knob, e trata os atalhos
  globais.
- **Ditado:** PCM mono 16 kHz em memória, enviado ao Deepgram (`nova-3`). O texto é inserido
  com eventos Unicode só depois que o overlay some.
- **Agentes:** junta o `terminal list` do Orca, os clientes tmux (casados com o Orca pelo
  `ORCA_TERMINAL_HANDLE`), os títulos que os agentes escrevem no terminal e os transcripts
  em `~/.claude`.
- **Luzes:** relatórios HID do fabricante na interface `0xFF00`.

## Desenvolvimento

```sh
zig build -Doptimize=ReleaseSafe && zig build test
AGENT_BELT_DEBUG_INPUT=1 zig-out/bin/agb daemon   # mostra cada tecla, knob e evento do tap
tools/make-icon.sh        # regenera o ícone
tools/render-overlay.sh   # regenera assets/overlay.gif
tools/render-menu.sh      # regenera assets/menu.png
```

O log fica em `~/Library/Logs/agent-belt.log`. Para desinstalar: `./install.sh --uninstall`.

---

<sub>O nome é uma homenagem ao cinto de utilidades 🦇. O projeto não tem relação com a DC
nem com a Warner.</sub>
