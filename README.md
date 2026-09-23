# agent-belt

Daemon macOS em Zig para transformar um agent-belt HID em atalhos configuráveis.

## Instalação

```sh
./install.sh
```

Compila, empacota em `~/Applications/Agent Belt.app` (assinado com o seu certificado
Apple Development, para as permissões sobreviverem a cada atualização), guarda
`DEEPGRAM_API_KEY` no Keychain e registra o LaunchAgent `com.frb.agentbelt`, que sobe
no login e renasce se cair. Na primeira vez, autorize "Agent Belt" em Monitoramento de
Entrada e Acessibilidade; o daemon tenta de novo a cada ~15 s e segue sozinho quando elas aparecem. O Microfone é pedido no primeiro
push-to-talk.

Links diretos: [Monitoramento de Entrada](x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent),
[Acessibilidade](x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility) e
[Microfone](x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone), ou `agb permissions`, que
abre os três; o daemon abre sozinho o que faltar.

A configuração vem do código: edite os padrões em `src/config.zig` e rode `./install.sh`
de novo, que regenera `~/.config/agent-belt/config.json` (`--keep-config` preserva o
arquivo). `./install.sh --uninstall` remove app, LaunchAgent e link. O log fica em
`~/Library/Logs/agent-belt.log` e o CLI em `~/.local/bin/agent-belt`.

## Estado atual

- monitoramento do teclado HID `VID=0x514c`, `PID=0x8850`;
- seis teclas (`a` a `f`, ou `0` a `5`) descobertas pelo uso HID `0x07/0x04..0x09`;
- tecla `3` (`d`) como push-to-talk e tecla `4` (`e`) alternando coding agents por padrão;
- gravação PCM mono 16 kHz em memória, empacotada como WAV;
- transcrição via Deepgram REST (`nova-3`, `smart_format` e `mip_opt_out`);
- inserção do resultado no aplicativo em foco usando eventos Unicode do macOS;
- cápsula flutuante no canto superior direito, com ondas que respondem ao áudio e se transformam em traços de texto durante a transcrição;
- bindings de `ptt`, `agents`, `command`, `script`, `text` e `disabled`;
- knob: girar rola a página e apertar leva os coding agents de volta ao fim;
- instalação opcional como LaunchAgent;
- indicador na barra de menus: `🔴 REC` enquanto grava, `⏳` durante a transcrição e `⚠︎` em caso de erro.

## Requisitos

- macOS;
- Zig 0.16+;
- permissão de Microphone para o binário;
- permissões de Input Monitoring/Accessibility para ler o HID e inserir texto;
- `DEEPGRAM_API_KEY` exportada no ambiente do daemon.

## Compilar e usar

```sh
zig build -Doptimize=ReleaseSafe
agb init
export DEEPGRAM_API_KEY='...'
agb daemon
```

Para ver a animação sem microfone nem teclado, execute `agb preview`.
Ela exibe quatro segundos de gravação simulada e quatro segundos de transcrição.
Durante o uso normal, a janela aparece no canto superior direito da tela onde está
o ponteiro do mouse. Ela não recebe foco nem cliques. Ao concluir, faz uma saída
de 120 ms; a inserção do texto aguarda a janela desaparecer por completo.
A preferência de acessibilidade “Reduzir movimento” também é respeitada.
A onda acompanha o áudio a cada 20 ms: volume aumenta sua altura e velocidade,
e os ataques das sílabas dão impulsos curtos de movimento. O medidor visual usa
uma escala de voz em decibéis; isso não altera o ganho do áudio enviado à API.

`zig build test` verifica a posição, preservação do foco, resposta ao nível de
áudio e fechamento completo antes de liberar a inserção. O teste abre o painel
por alguns segundos e exige uma sessão gráfica do macOS; não usa microfone nem API.

Configuração é salva em `~/.config/agent-belt/config.json`.

Na primeira execução, autorize o binário em Ajustes do Sistema → Privacidade e
Segurança:

- Input Monitoring, para o daemon poder ler os eventos do teclado HID;
- Accessibility, para inserir o texto no aplicativo em foco;
- Microphone, para a gravação.

Se o binário for recompilado em outro caminho, o macOS pode pedir a autorização
novamente. O daemon reporta `HidOpenFailed` quando o primeiro desses acessos ainda
não foi concedido.

Para diagnosticar a correlação entre o HID e os eventos de teclado do macOS:

```sh
AGENT_BELT_DEBUG_INPUT=1 agb daemon
```

Ao pressionar `a`, o diagnóstico deve mostrar `HID key=0 down` e um evento `TAP`
correspondente com `suppress=yes`. O daemon também imprime `GRAVANDO`,
`TRANSCRIVENDO` e `INSERIDO` durante o fluxo de push-to-talk.

Exemplos:

```sh
agb bind a ptt
agb bind b command 'open -a Calculator'
agb bind c script '/Users/frb/bin/meu-script.sh'
agb bind d text 'Olá!'
agb bind e disabled
agb bind 4 agents
```

Para rodar no login, compile o binário e execute `agb install`; depois carregue o plist com o comando mostrado. Variáveis de ambiente de um LaunchAgent precisam ser configuradas pelo próprio ambiente do usuário — para a chave, a forma recomendada é criar um pequeno wrapper local que exporte `DEEPGRAM_API_KEY` e chamar esse wrapper no plist.

## Nota sobre captura

O daemon usa o monitor HID sem privilégios de root e um CGEvent tap para
suprimir os eventos `a`–`f` correlacionados ao agent-belt, evitando que eles
também sejam digitados no aplicativo ativo.
Após soltar uma tecla, ele mantém a supressão por 100 ms para absorver eventos
de repetição atrasados do macOS.

## Alternar coding agents

A ação `agents` funciona como um alt-tab entre terminais com agentes rodando:

- terminais do Orca em que o próprio Orca reconhece um agente;
- terminais do Orca anexados a uma sessão tmux do `work` (o daemon lê `ORCA_TERMINAL_HANDLE` do cliente `tmux attach`);
- sessões do `work` anexadas em outro app de terminal, que vem para frente.

A tecla vai primeiro para quem precisa de você: um agente **aguardando aprovação**
(prompt de permissão na tela ou `agentWait` do Orca), depois um que **terminou** e você
ainda não viu (título saiu do spinner para `✳`), e só então segue o anel. Um HUD no canto
direito mostra o agente, a posição e o estado; `agents list` mostra o estado de todos.

Uma sessão só conta enquanto algum pane roda `claude`, `codex`, `opencode`, `gemini` etc.;
se o agente encerrar, ela sai do anel. A ordem é estável e a posição fica em
`~/Library/Caches/agent-belt/last-agent`. Para incluir também as janelas do Codex e
do Claude Desktop: `bind 4 agents desktop`. Requer Accessibility.

```sh
agb agents list
agb agents next
agb agents bottom
```

## Menu de agentes (tecla 1)

Um toque abre um menu flutuante com todos os agentes e o estado de cada um: vermelho
aguardando uma decisão sua, verde terminou, azul trabalhando, cinza ocioso. Ele já começa
em quem mais precisa de você. Com o menu aberto, um toque desce para o próximo e um duplo
toque rápido abre o destacado. Some sozinho depois de 6 s sem toques.

## Sem o tecladinho

| Atalho | Ação |
|---|---|
| `⌃⌥Espaço` | menu de agentes; repetir navega, `↩` abre, `Esc` fecha, `↑`/`↓` movem |
| `⌃⌥↑` | próximo agente |
| `⌃⌥↓` | agentes de volta ao fim |

A barra de menus mostra 🔴 quando um agente aguarda você, 🟢 quando um terminou, 🎙️
gravando e ⏳ transcrevendo; um clique abre o mesmo menu, com linhas clicáveis. Longe do
Mac, um agente esperando há 3 min manda um aviso no WhatsApp. O menu traz título, recap,
tempo, custo e tokens de cada sessão e as cotas dos planos; ver
[docs/agent-stats.md](docs/agent-stats.md).

## Knob

O knob chega como Consumer Control (volume +/− e mute). O daemon transforma:

- **girar** em scroll de linhas sob o ponteiro (horário desce). Giros rápidos aceleram até 4x;
- **apertar** em "voltar ao fim": todo pane tmux de agente que esteja no histórico
  (copy-mode) volta para a saída ao vivo, e a view de agente sob o ponteiro rola até o final.

O volume e o mute do knob são bloqueados no event tap enquanto o HID acabou de
registrar o knob; as teclas de volume do próprio Mac continuam funcionando. No config:

```json
"knob": "scroll",
"knob_scroll_lines": 3
```

`"knob": "system"` devolve o controle de volume; um `knob_scroll_lines` negativo inverte
o sentido. Nas sessões `work`, o tmux precisa de `mouse on` (o `work` já liga) para a
roda rolar o copy-mode em vez de virar setas no prompt do agente.

## LEDs

As teclas acendem conforme o estado: **branco** gravando, **ciano** transcrevendo,
**vermelho** quando um agente aguarda você, **verde** quando um terminou e você ainda não
viu (a tecla 4 leva até ele) e, sem nada pendente, uma onda branca a cada toque. Protocolo
e cores em [docs/led-protocol.md](docs/led-protocol.md). `"led": false` desliga;
`agb led <cor> <modo>` troca à mão.

## Criar agentes por voz

Com o menu de agentes aberto (tecla 1 ou `⌃⌥Espaço`), segure o push-to-talk e peça:
*"crie um agente no windows com codex no coreum para investigar o login"*. O Deepgram
transcreve, um Claude Haiku (`claude -p`, com a sua conta) extrai máquina, agente,
repositório, nome da tarefa e instrução, e um terminal novo no Orca roda o `work` com
`--prompt`. Sem o Orca, abre no Terminal. O mesmo pelo terminal, ou por outro agente:

```sh
agb new --dry-run crie um agente no windows com codex no coreum para investigar o login
# work felipe-windows investigar-login coreum --agent codex --prompt '…'
agb new crie um agente aqui com claude no agent-belt para revisar o README
```

## work: sessões de agente em qualquer máquina

`work/` (antes o repositório `tmux`, trazido com o histórico) cria uma sessão tmux com
um worktree e um agente dentro, em qualquer máquina do tailnet: `work <tarefa> [repo]`,
`work <máquina> <tarefa> [repo] --codex`. O `./install.sh` instala `work`, `work-session`
e `tm`; para as outras máquinas, `work/scripts/deploy.sh --all`. Detalhes em
[work/README.md](work/README.md).
