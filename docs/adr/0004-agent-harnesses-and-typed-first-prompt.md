---
type: ADR
id: "0004"
title: "Agent harnesses and the typed first prompt"
status: active
date: 2026-09-25
---

## Context

A session ran one of three things: Claude Code, Codex or a shell. The list was
repeated in every layer: the `local.Agent` enum, the Jev question, the exact-name
matcher, the speech keyterms, and hard-coded arrays in the macOS panel, the Linux
QML panel and the Windows dialog. Adding DeepSeek Harness, ZCode and fx meant
touching all of them, and the next harness would mean the same.

The three new harnesses do not start the way Claude Code and Codex do:

- **ZCode** (`zcode`) and **fx** (`fx`) are terminal UIs that take no first prompt
  on their command line (`zcode "…"` and `fx "…"` print their help); a prompt
  flag runs them headless and exits.
- **DeepSeek Harness** installs as `dsh` and ships no terminal UI: its profiles
  are `web`, `headless`, `sdk` and `acp`. `dsh --profile headless "job"` runs one
  task and prints the answer.

## Decision

1. **`local.Agent` is the single list of harnesses.** `Agent.program()` names the
   executable (`deepseek` → `dsh`), `local.agent_names` feeds the speech keyterms,
   and the intent plan carries it as `agents`, which the macOS, Linux and Windows
   pickers show. Recognition of a running harness (`isAgentCommand`, `inferAgent`)
   reads one table of program names.
2. **A harness without a prompt argument gets its first prompt typed by tmux.**
   After `new-session`, a `tmux run-shell -b` script waits until the pane shows
   the same non-empty screen twice half a second apart (at most 20 s), then pastes
   the prompt file with `paste-buffer -p` (bracketed paste when the program asks
   for it) and presses Enter. It runs inside the tmux server, so attaching does
   not wait and the session survives the caller.
3. **DeepSeek Harness runs headless in the session**, `dsh --profile headless
   "<prompt>"` followed by the login shell in the same pane. Without a prompt,
   `agb new` refuses (`PromptRequired`).
4. Adoption of agents started outside tmux stays limited to Claude Code and Codex,
   the two whose conversation id agb can read.

## Consequences

- A new harness is an enum member, its command in `agentCommand`, and its
  program name in the recognition table; every picker gets it from the plan.
- The typed prompt depends on the program drawing a stable screen; one that
  animates forever gets the prompt at the 20 s mark.
- A DeepSeek session is one task and then a shell, not a conversation you keep
  talking to. If DeepSeek ships a terminal profile, this decision is superseded.
