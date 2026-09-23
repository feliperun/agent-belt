# Protocolo dos LEDs (514c:8850, 6 teclas + knob)

Obtido por engenharia reversa do configurador oficial para Mac
(`http://www.szxiaozi.com/MACEN.zip`, `MINI_KEYBOARD.app`, função
`Widget::SetRgb_Led_Key` e `Widget::HID_write`) e confirmado no hardware em
2026-09-23. Nada daqui vem de documentação do fabricante.

## Transporte

- Interface de configuração: usage page `0xFF00`, usage `0x01`, report ID `0x03`.
- Output reports de 65 bytes (report ID + 64 de dados, zeros no resto), via
  `IOHIDDeviceSetReport(dev, kIOHIDReportTypeOutput, 0x03, buf, 65)`.
- O dispositivo só responde ~250 ms depois de aberto.
- Escritas com menos de ~150 ms de intervalo são descartadas em silêncio; use 300 ms.

## Sequência

```
03 FB FB FB                                     identificação; responde 03 FB 06 01 (6 teclas, 1 knob)
  300 ms
03 FE B0 01 08 00 00 00 00 00 01 00 <cor<<4|modo>
```

Sem a identificação logo antes, o comando de LED é ignorado. O commit
`03 FD FE FF` que o app manda depois **não é necessário**: o próprio comando de
LED já é persistido (a cor sobrevive a desplugar). Cada troca grava a flash.

| byte | valor | significado |
|---|---|---|
| 1–2 | `FE B0` | comando de LED |
| 3 | `01` | camada, começando em 1 |
| 4 | `08` | tipo "LED" (o app usa `01` teclas, `02` mídia, `03`/`05` mouse) |
| 10 | `01` | fixo |
| 12 | `cor<<4 \| modo` | |

Cores (tabela do app): `1` vermelho, `2` laranja, `3` amarelo, `4` verde,
`5` ciano, `6` azul, `7` roxo. Cor `0` apaga no modo fixo e é **branco** no modo reativo.

Modos, como observados neste exemplar (o manual diz outra coisa para 2 e 3):

| modo | efeito |
|---|---|
| 0 | apagado |
| 1 | cor fixa |
| 2 | reativo: apagado; uma onda da cor passa ao apertar e ao soltar uma tecla (cor 0 = branca) |
| 5 | branco fixo |

Os modos 3 e 4 não foram testados. Não há arco-íris no firmware; o daemon faz a
animação do push-to-talk trocando a cor fixa.

## Comandos que nunca devem ser enviados

Do mesmo canal, segundo outros projetos para este VID:PID:

- `03 FD <slot> …`: regrava o mapeamento de uma tecla na flash.
- `03 FC FC …`: troca o modelo do teclado de forma persistente e irreversível.
- 64 bytes zerados (o "init" do ch57x-keyboard-tool).
- O formato com RGB por tecla (`03 FE B0 <camada-1> <modo> R G B …`) é de outro
  firmware com o mesmo VID:PID; aqui não faz nada.

## Uso no minikeyboard

`src/led.m`: uma thread aplica sempre o último estado desejado e pula escritas
repetidas. Prioridade: gravando (arco-íris) > transcrevendo (ciano fixo) >
agente aguardando você (vermelho) > agente terminou e não foi visto (verde) >
base (onda branca reativa, `02`). `"led": false` na config desliga. Manual:
`minikeyboard led <cor> <modo>`.
