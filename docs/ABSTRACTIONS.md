# Abstractions

The vocabulary of the codebase.

## Layers

- **Input** (`macos_shim.c`, `daemon.zig`): HID values and tap events become key edges,
  knob detents and F5 presses; bindings map keys to actions.
- **Agents** (`agent_switcher.m`, `agent_stats.m`): discovery, state, priority, focus
  and per-session facts.
- **Presentation** (`status_item.m`, `led.m`): overlay, HUD, menus and key lights, all
  driven by state, never by input directly.
- **Sessions** (`work/`): creating and attaching tmux agent sessions on any host.

## Core terms

| Term | Meaning |
|---|---|
| Binding | what a keypad key does: `ptt`, `agents`, `menu`, `key`, `command`, `script`, `text` |
| Target | one agent the switcher can focus: an Orca terminal, or a tmux session attached in some terminal |
| Ring | the stable order of targets the switch key walks |
| State | idle, working, done (finished and not seen), waiting (needs your decision) |
| Session info | title, recap, time, tokens, cost read from an agent's transcript |
| Snapshot | the last agent list seen by the 5 s monitor, used by the menu bar |

## External systems and their boundaries

| System | Boundary |
|---|---|
| Keypad (514c:8850) | HID values in; vendor output reports for LEDs (`led.m`) |
| Deepgram | one REST call per recording (`deepgram.zig`) |
| Orca | its CLI (`orca terminal list/show/switch/create`) via `MKOrca` |
| tmux | `list-panes`, `list-clients`, `capture-pane`, `send-keys` via `MKTmux` |
| Claude Code / Codex | read-only: `~/.claude/sessions`, transcripts, `~/.codex/sessions` |
| `claude -p` | turns a spoken request into `agb new` arguments |
| GitHub | release checks and source tarballs |

## Invariants

- The event tap never blocks; slow work runs on queues.
- Text is inserted only after the overlay has fully disappeared.
- An LED state is written once; repeats are skipped.
- The switcher never trusts Orca for UI focus; it keeps its own position.
