# Changelog

## 0.1.0 (2026-09-23)

Primeira versão do Agent Belt (antes minikeyboard).

### Features

* push-to-talk com transcrição Deepgram e overlay animado (ouvindo / decifrando)
* troca de coding agents na tecla 4, indo primeiro para quem aguarda você ou terminou; HUD da troca
* menu de agentes na tecla 1, `⌃⌥Espaço` ou clique na barra de menus: título, recap, tempo, custo, tokens e cotas do Claude e do Codex
* criar agentes por voz ou com `agb new`, via `work --prompt` em qualquer máquina do tailnet
* LEDs das teclas: branco gravando, ciano transcrevendo, vermelho aguardando, verde terminou, onda branca reativa
* knob rola a página; o botão leva os agentes de volta ao fim
* Esc, Delete e Return nas teclas 0, 2 e 5; atalhos no teclado do Mac para usar sem o tecladinho
* aviso no WhatsApp quando um agente espera por você com o Mac ocioso
* `work`/`tm` (ex-repositório tmux) incluídos; instalador com LaunchAgent, ícone, links para as permissões e atualização automática
