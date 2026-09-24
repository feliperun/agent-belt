# Roadmap

Ideas that are agreed on but not built yet, most valuable first. When one ships, it
leaves this file (the CHANGELOG records it).

## Next

### Real-time dictation on Windows and Linux

On the Mac the words stream into the overlay while the key is held and are typed on release
(`src/live_recording.zig` over `src/transcribe_stream.zig`). The Windows tray and the Linux
bindings still send the recording whole on release; the streaming client is portable, so
they can show the words live the same way.

### Quota and reset watch

A periodic check, per harness installed on the machine (Claude Code, Codex, DeepSeek, GLM),
of usage and quotas: the 5-hour and weekly windows and when each resets. The menu shows it
at any time, as a small usage panel. When a weekly quota comes back, or a vendor grants an
extra reset, a happy, animated pop-up says so: the dictation overlay's sibling with a little
more color, and a cheerful sound. The 5-hour window resetting is not announced.

### Adopt the agent on screen

An agent started in a hurry, outside Agent Belt, lives only in that terminal and cannot be
followed from another machine. A shortcut (and a menu item, and a double press on the
switch key) takes the agent in the focused window into tmux: it finds that terminal's agent
process and its conversation id, stops it and reopens the same conversation in a tmux
session (`claude --resume <id>`, `codex resume <id>`), attached where it was. `agb adopt`
already does this from the command line; the turn in progress is lost, the conversation is
not. The agent menu also lists the sessions of the other machines, to open them from here.

## Later

### Agent state on every platform

Today only the Mac knows which agent is waiting for a decision (red) or just finished
(green). Carry that state in the session protocol (`agb _ls-raw`) so the Windows tray,
the Omarchy bar module and orchestrators such as Hermes see it too.

### Updates on Windows and Linux

Releases only publish the macOS app; other machines are updated with `agb deploy` from
a checkout. Publish Linux and Windows binaries with each release, make `agb update`
work everywhere, and have the Windows tray announce new versions like the Mac.

### Clean session names

Sessions named from a Claude Code title keep its status glyph and lose accents
(`_-leave`, `cust_dia`). Strip the glyph and transliterate accents when naming.

### Worktree cleanup

`agb stop` ends the session but keeps its worktree and branch. `agb clean` removes the
worktrees whose branches are merged.

### End-to-end session tests in CI

CI cross-builds for Linux and Windows but runs nothing there. A Linux runner with tmux
exercising `new`, `send`, `peek` and `stop` would catch platform bugs before they reach
a machine.

### Parity

- The create-agent panel on Windows (tray, a hotkey) and Omarchy (a Hyprland bind and a
  Quickshell panel): `agb _intent` and the streaming client are already portable.
- Repos listed under their project name when the folder differs (`minikeyboard` is
  agent-belt), so it can be said aloud.
- The keypad and its lights on Linux (evdev, hidraw) if it is used there.
