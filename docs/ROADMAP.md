# Roadmap

Ideas that are agreed on but not built yet, most valuable first. When one ships, it
leaves this file (the CHANGELOG records it).

## Next

### Push-to-talk to create an agent

Hold key 5 on the keypad: a floating panel opens at the center of the screen, visually
the sibling of the dictation overlay, recording and transcribing in real time while it
detects the four parts of a new agent: harness (claude, codex, shell), machine, repo
and intent. Releasing stops recording but keeps the panel open for review: hold again
to add or correct by voice, type to fix a wrong word (the panel grows), tap 5 (Enter)
to create the agent on the chosen machine. With a single machine (no tailnet, or only
this one in the registry), the machine is always this one; nothing is invented. Repos
are looked up in configured work roots, with a cached index per machine so detection
does not wait on ssh.

### Real-time transcription

Stream the audio to Deepgram while the key is held (its live WebSocket API) instead of
uploading it on release, so the text is ready the moment the key comes up. The
streaming client is shared by dictation and agent creation. Open question for
dictation: show the live transcript in the overlay and insert it on release, or type it
into the focused field as it arrives.

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

- Voice-created agents from the Windows tray and the Omarchy bindings.
- The keypad and its lights on Linux (evdev, hidraw) if it is used there.
