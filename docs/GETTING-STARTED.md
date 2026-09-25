# Getting Started

## Prerequisites

- Zig 0.16 (`brew install zig`, or your distribution's package).
- A Deepgram API key (`DEEPGRAM_API_KEY`) to dictate. Agent sessions need none.
- [Sentrux CLI](sentrux.md#install) for the structural quality gate.
- To work on the keypad, overlay and menus: macOS 14+ and the Xcode Command Line
  Tools — they are AppKit and IOKit code. Optional there: the 514c:8850 macropad,
  Orca terminals, tmux.

`agb`, the session CLI, builds and runs on macOS, Linux and Windows; the daemon and
its UI are macOS, the tray app is Windows, and the compositor binds are Hyprland. CI
builds all three targets, so a change must keep them compiling even if you only run one.

## Quick start

macOS:

```bash
export DEEPGRAM_API_KEY=...
./install.sh          # build, bundle, sign, Keychain, LaunchAgent
agb status            # daemon, permissions, device, key
```

Grant **Agent Belt** Input Monitoring and Accessibility when asked (`agb permissions`).

Linux or Windows, where there is no installer to run from a clone:

```bash
zig build -Doptimize=ReleaseSafe
zig-out/bin/agb hosts        # the session CLI is the whole product here
```

## Daily commands

```bash
zig build -Doptimize=ReleaseSafe && zig build test   # build + tests
zig build -Dtarget=x86_64-linux-musl  -Doptimize=ReleaseSafe   # keep the other
zig build -Dtarget=x86_64-windows-gnu -Doptimize=ReleaseSafe   # targets compiling
sentrux check .           # architectural rules
sentrux gate .            # no structural regression
AGENT_BELT_DEBUG_INPUT=1 zig-out/bin/agb daemon      # see every key, knob and tap event
```

`zig build test` runs every Zig module listed in `build.zig`'s `test_step` plus the
macOS GUI tests in `tests/`. A module's `test` blocks run **only** when the module is
in that list: importing it from a listed one is not enough.

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
- [Sessions](sessions.md) — agent sessions across machines
- [SECURITY.md](../SECURITY.md) — what Agent Belt trusts, and how to report a flaw
- [AGENTS.md](../AGENTS.md) — the contributor/agent playbook

## First contribution checklist

- [ ] Read [AGENTS.md](../AGENTS.md), especially the gotchas.
- [ ] Run the check suite locally and confirm it's green, including the two
      cross-compile targets.
- [ ] `sentrux gate --save .` before touching existing files.
- [ ] No personal data in the diff: examples are `macbook`, `linux-box`, `windows-pc`,
      the user `alice` and repositories like `web-app`, never a real machine, person or
      company.
- [ ] A new Zig module with tests goes into `build.zig`'s `test_step` list, or its
      tests never run.
