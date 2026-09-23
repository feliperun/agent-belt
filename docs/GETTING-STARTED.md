# Getting Started

## Prerequisites

- macOS 14+, Xcode Command Line Tools, Zig 0.16 (`brew install zig`).
- A Deepgram API key (`DEEPGRAM_API_KEY`).
- Optional: the 514c:8850 macropad, Orca terminals, tmux.
- [Sentrux CLI](sentrux.md#install) for the structural quality gate.

## Quick start

```bash
export DEEPGRAM_API_KEY=...
./install.sh          # build, bundle, sign, Keychain, LaunchAgent
agb status            # daemon, permissions, device, key
```

Grant **Agent Belt** Input Monitoring and Accessibility when asked (`agb permissions`).

## Daily commands

```bash
zig build -Doptimize=ReleaseSafe && zig build test   # build + tests
sentrux check .           # architectural rules
sentrux gate .            # no structural regression
AGENT_BELT_DEBUG_INPUT=1 zig-out/bin/agb daemon      # see every key, knob and tap event
```

## Worktree workflow

```bash
git worktree add ../agent-belt-<task> -b <dev>/<issue>-<slug>
```

## Documentation map

- [Vision](VISION.md) — why this exists
- [Architecture](ARCHITECTURE.md) — current-state structure
- [Abstractions](ABSTRACTIONS.md) — the vocabulary
- [ADRs](adr/README.md) — decision history
- [Sentrux](sentrux.md) — the quality gate
- [AGENTS.md](../AGENTS.md) — the contributor/agent playbook

## First contribution checklist

- [ ] Read [AGENTS.md](../AGENTS.md), especially the gotchas.
- [ ] Run the check suite locally and confirm it's green.
- [ ] `sentrux gate --save .` before touching existing files.
