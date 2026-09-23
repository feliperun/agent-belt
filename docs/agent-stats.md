# Estatísticas e cotas dos agentes

O menu de agentes mostra, por sessão, título, recap, tempo, custo e tokens, e as
cotas dos planos no rodapé. Tudo vem de arquivos locais dos próprios agentes;
nada é enviado nem autenticado. Código em `src/agent_stats.m`.

| Dado | Fonte |
|---|---|
| sessão viva → transcript | `~/.claude/sessions/<pid>.json` (`sessionId`, `tmux` com o pane, `startedAt`, `parkedJobId`/`jobId` para sessões estacionadas em processo de fundo) |
| casar com o terminal | pane do tmux (`%24`) ou `ORCA_TERMINAL_HANDLE` do processo |
| título | último `custom-title`, senão `ai-title` do transcript |
| recap | último `system/away_summary`, senão `last-prompt` |
| tokens e custo | `message.usage` de cada `assistant`, **deduplicado por `message.id`** (uma linha por bloco, usage repetido), mais `subagents/*.jsonl`; preço de lista da Anthropic (tabela no código, 2026-09-23) |
| tempo | `startedAt` do processo |
| cota Claude | só existe no JSON que o Claude Code passa ao statusline: `~/.claude/statusline-command.sh` salva o último em `~/Library/Caches/agent-belt/claude-statusline.json` (`rate_limits.five_hour`/`seven_day`) |
| cota Codex | último `token_count` com `rate_limits.primary` (5 h) e `secondary` (7 d) nos rollouts de `~/.codex/sessions` |

Os transcripts são lidos de forma incremental (offset por arquivo) e só as linhas
com marcadores relevantes passam pelo parser. O custo é o equivalente em API:
em planos de assinatura, não é cobrança.

Sessões do Codex ainda não têm título/custo por sessão (o mapeamento processo →
rollout não foi verificado com um Codex vivo); a cota do Codex aparece.

## Aviso no WhatsApp

Um agente aguardando uma decisão por 3 min, com o Mac sem uso por 2 min, gera uma
mensagem via `ford-send` com o título da sessão, uma vez por espera.
