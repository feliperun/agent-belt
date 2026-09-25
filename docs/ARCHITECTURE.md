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
                                        └─> session engine (Zig) ─> tmux + worktree + agent, any host
```

A single LaunchAgent process (`agb daemon`) owns the input, the UI and the agent
bookkeeping on macOS. The CLI (`agb`) is the same binary, and on Linux and Windows
`agb` is the session CLI (built by `agb deploy`).

## Components

| Path | Responsibility |
|---|---|
| `src/main.zig` | CLI entry point: daemon, status, agents, sessions, LEDs, updates |
| `src/daemon.zig` | key bindings, push-to-talk flow, knob, F5 |
| `src/macos_shim.c` | HID monitor, event tap (swallowing and global shortcuts), audio capture, key injection |
| `src/status_item.m` | overlay, switch HUD, agent menu, menu bar icon and menu |
| `src/agent_switcher.m` | agent discovery (Orca + tmux here, every machine's sessions through `agb _sessions`), states, priority, focus, voice commands |
| `src/agent_stats.m` | titles, recaps, tokens, cost and quotas from local agent files |
| `src/led.m` | keypad LED worker (latest state wins, repeats skipped) |
| `src/updater.m` | release checks, notifications, source updates |
| `src/system.m` | permissions, Keychain, single instance, `agb status` |
| `src/create_panel.m`, `src/create_agent.zig` | the create-agent panel (key 5): streamed transcript, detected fields, confirmation |
| `src/history.zig` | every recording (audio + transcript) kept 60 days; `agb history` |
| `src/transcribe_stream.zig` | real-time transcription: Deepgram's live API over a std-only WebSocket client |
| `src/sessions/` | agent sessions on any tailnet host: registry, tmux, worktrees, ssh protocol (all platforms); `intent.zig` + `jev.zig` turn a spoken request into agent, machine, repo and intent; `deepseek.zig` cleans the request for the agent and names the session; `local.Agent` is the list of harnesses (claude, codex, deepseek, zcode, fx, shell) every picker reads ([ADR 0004](adr/0004-agent-harnesses-and-typed-first-prompt.md)) |
| `src/linux/` | the Linux desktop commands run by compositor binds: `menu` (Omarchy's menu or walker), `waybar`, `ptt` (pw-record, wtype), Hyprland `install`; `overlay.qml` is the dictation overlay, hosted in Quickshell, with the words streamed by `src/wav_stream.zig`; `agent_panel.zig` + `agent_panel.qml` are the create-agent panel (Shift+F9); `bar.qml` is the belt with the agent count in Omarchy's bar |
| `src/windows/` | the Windows tray daemon (`agent-belt.exe`): notification-area menu and belt icon with the agent count, push-to-talk, Win32 bindings; `gdiplus.zig` holds what the GDI+ surfaces share (ink, shell, core, belt), `overlay.zig` draws the dictation overlay and `create_panel.zig` the create-agent panel |
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

Full statement, including the trust boundaries of the machine mesh: [SECURITY.md](../SECURITY.md).

- The Deepgram key lives in the login Keychain, readable by the signed app only.
- What leaves the machine: audio to Deepgram, and — when a spoken request has to be
  understood — the same request text to Jev (`api.typesafe.ai`) and to DeepSeek
  (`api.deepseek.com`), which name the session and strip the routing words. Plus GitHub
  release checks and, if the user configured a sender, the away alert (session title only).
- Agent screens are read locally to detect approval prompts and never logged.
- Voice commands become `agb new` arguments validated against known hosts and a safe
  charset before reaching a shell.
- Every machine listed in `~/.config/work/hosts.conf` is trusted to run `agb` here over
  ssh, which includes creating an agent session. The registry is itself an input:
  `agb deploy` rewrites it on the machines it installs to.

## Related docs

- [Vision](VISION.md) · [Abstractions](ABSTRACTIONS.md) · [ADRs](adr/README.md) · [Sentrux](sentrux.md)
- [LED protocol](led-protocol.md) · [Agent stats](agent-stats.md)
