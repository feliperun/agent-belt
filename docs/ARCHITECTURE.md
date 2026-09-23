# Architecture

> Current-state summary. ADRs in [adr/](adr/README.md) hold the history and the
> *why*; this file reflects only **active** decisions. Update it in the same
> commit as any structural change.

## High-level flow

```
macropad (HID) ─┐                       ┌─> Deepgram (transcript) ─> Unicode key events
Mac keyboard ───┼─> event tap + HID ────┼─> agent switcher ─> Orca CLI / tmux / Accessibility
knob ───────────┘   monitor (daemon)    ├─> key LEDs (vendor HID reports)
                                        ├─> overlay, HUD, agent menu, menu bar (AppKit)
                                        └─> work engine (bash) ─> tmux + worktree + agent, any host
```

A single LaunchAgent process (`agb daemon`) owns the input, the UI and the agent
bookkeeping. The CLI (`agb`) is the same binary.

## Components

| Path | Responsibility |
|---|---|
| `src/main.zig` | CLI entry point: daemon, status, agents, sessions, LEDs, updates |
| `src/daemon.zig` | key bindings, push-to-talk flow, knob, F5 |
| `src/macos_shim.c` | HID monitor, event tap (swallowing and global shortcuts), audio capture, key injection |
| `src/status_item.m` | overlay, switch HUD, agent menu, menu bar icon and menu |
| `src/agent_switcher.m` | agent discovery (Orca + tmux), states, priority, focus, voice commands |
| `src/agent_stats.m` | titles, recaps, tokens, cost and quotas from local agent files |
| `src/led.m` | keypad LED worker (latest state wins, repeats skipped) |
| `src/updater.m` | release checks, notifications, source updates |
| `src/system.m` | permissions, Keychain, single instance, `agb status` |
| `work/` | portable bash engine for tmux agent sessions on any tailnet host |
| `install.sh` | build, bundle, sign, Keychain, LaunchAgent |

## Runtime & hosting

macOS 14+. `install.sh` builds `~/Applications/Agent Belt.app`, signs it with the
local Apple Development identity (so privacy grants survive rebuilds) and registers
the `com.frb.agentbelt` LaunchAgent (`KeepAlive`). Releases come from release-please;
`agb update` rebuilds a release from source.

## Observability & quality

- Build and tests (unit + macOS GUI) run on every push in `ci.yml` on a macOS runner.
- Structural health gated by [Sentrux](sentrux.md) in `quality.yml`.
- Errors and events go to `~/Library/Logs/agent-belt.log`; `agb status` summarizes.

## Security model

- The Deepgram key lives in the login Keychain, readable by the signed app only.
- Audio leaves the machine only for Deepgram; nothing else is sent anywhere except
  the optional WhatsApp alert (session title only) and GitHub release checks.
- Agent screens are read locally to detect approval prompts and never logged.
- Voice commands become `agb new` arguments validated against known hosts and a safe
  charset before reaching a shell.

## Related docs

- [Vision](VISION.md) · [Abstractions](ABSTRACTIONS.md) · [ADRs](adr/README.md) · [Sentrux](sentrux.md)
- [LED protocol](led-protocol.md) · [Agent stats](agent-stats.md)
