# minikeyboard

Daemon macOS em Zig para transformar um minikeyboard HID em atalhos configuráveis.

## Estado atual

- monitoramento do teclado HID `VID=0x514c`, `PID=0x8850`;
- seis teclas (`a` a `f`) descobertas pelo uso HID `0x07/0x04..0x09`;
- `a` configurada como push-to-talk por padrão;
- gravação PCM mono 16 kHz em memória, empacotada como WAV;
- transcrição via Deepgram REST (`nova-3`, `smart_format` e `mip_opt_out`);
- inserção do resultado no aplicativo em foco usando eventos Unicode do macOS;
- cápsula flutuante no canto superior direito, com ondas que respondem ao áudio e se transformam em traços de texto durante a transcrição;
- bindings de `ptt`, `command`, `script`, `text` e `disabled`;
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
zig-out/bin/minikeyboard init
export DEEPGRAM_API_KEY='...'
zig-out/bin/minikeyboard daemon
```

Para ver a animação sem microfone nem teclado, execute `zig-out/bin/minikeyboard preview`.
Ela exibe quatro segundos de gravação simulada e quatro segundos de transcrição.
Durante o uso normal, a janela aparece no canto superior direito da tela onde está
o ponteiro do mouse. Ela não recebe foco nem cliques. Ao concluir, faz uma saída
de 120 ms; a inserção do texto aguarda a janela desaparecer por completo.
A preferência de acessibilidade “Reduzir movimento” também é respeitada.

`zig build test` verifica a posição, preservação do foco, resposta ao nível de
áudio e fechamento completo antes de liberar a inserção. O teste abre o painel
por alguns segundos e exige uma sessão gráfica do macOS; não usa microfone nem API.

Configuração é salva em `~/.config/minikeyboard/config.json`.

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
MINIKEYBOARD_DEBUG_INPUT=1 zig-out/bin/minikeyboard daemon
```

Ao pressionar `a`, o diagnóstico deve mostrar `HID key=0 down` e um evento `TAP`
correspondente com `suppress=yes`. O daemon também imprime `GRAVANDO`,
`TRANSCRIVENDO` e `INSERIDO` durante o fluxo de push-to-talk.

Exemplos:

```sh
zig-out/bin/minikeyboard bind a ptt
zig-out/bin/minikeyboard bind b command 'open -a Calculator'
zig-out/bin/minikeyboard bind c script '/Users/frb/bin/meu-script.sh'
zig-out/bin/minikeyboard bind d text 'Olá!'
zig-out/bin/minikeyboard bind e disabled
```

Para rodar no login, compile o binário e execute `zig-out/bin/minikeyboard install`; depois carregue o plist com o comando mostrado. Variáveis de ambiente de um LaunchAgent precisam ser configuradas pelo próprio ambiente do usuário — para a chave, a forma recomendada é criar um pequeno wrapper local que exporte `DEEPGRAM_API_KEY` e chamar esse wrapper no plist.

## Nota sobre captura

O daemon usa o monitor HID sem privilégios de root e um CGEvent tap para
suprimir os eventos `a`–`f` correlacionados ao minikeyboard, evitando que eles
também sejam digitados no aplicativo ativo.
Após soltar uma tecla, ele mantém a supressão por 100 ms para absorver eventos
de repetição atrasados do macOS.
