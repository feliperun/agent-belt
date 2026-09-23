# AGENTS.md — agent-belt

> [Architecture](docs/ARCHITECTURE.md) · [Abstractions](docs/ABSTRACTIONS.md) · [Vision](docs/VISION.md) · [Getting Started](docs/GETTING-STARTED.md) · [ADRs](docs/adr/README.md) · [Sentrux](docs/sentrux.md)

Write the minimum code that runs. No fluff, no gold-plating.

- Do not preserve backward compatibility. Remove obsolete paths instead of adding
  compatibility layers, fallbacks, or migrations.
- Choose the simplest implementation that fully meets the current requirements.
  Avoid speculative abstractions, configuration, and indirection.
- Grow the system in layers. Start from the smallest version that works end to end,
  and add each new capability on top of a product that already works. Never trade a
  working product for unfinished complexity.
- Keep components modular and concerns clearly separated.
- Prefer established, well-maintained libraries when they reduce overall complexity
  or improve reliability. Do not reimplement common functionality without a clear reason.
- Lean on the dependencies already in the project before writing your own
  implementation or adding packages. Do not assume a library lacks a capability
  without checking its documentation and types.
- Make architectural decisions for the long term. Do not accept a stopgap that only
  works for now and is meant to be replaced later.
- Study how established products solve the problem before designing a solution. Adopt
  their proven patterns and conventions rather than inventing an approach from scratch.

## Repository rules

- **`AGENTS.md` is the single source of guidance.** `CLAUDE.md`, `GEMINI.md`,
  `CURSOR.md` and `AGENT.md` are symlinks to it.
  Never edit a symlink; never let one drift into a real file.
- **Continuity beats restart.** Before starting new work, check `.runs/` and the
  managed signal block at the bottom of this file: an active campaign or a
  non-terminal run is work to continue — read its `HANDOFF.md`/`STATUS.md`,
  re-attach the session, and `resume` or `supervise` — not to redo.
- **Never commit secrets.** Tokens, credentials, and service-account JSON stay in a
  secret manager or a gitignored `.env`. The `pre-commit` hook scans the staged diff;
  do not work around it.
- **No personal or production-derived data in source**, migrations, fixtures, tests,
  or docs. Committed fixtures are synthetic. User-specific values belong in runtime
  configuration.
- **Never expose internals to users.** No stack traces, internal URLs, or env var
  names in user-facing copy.
- **Conventional Commits required.** `feat:`, `fix:`, `docs:`, `refactor:`, `test:`,
  `chore:`. One logical change per commit; one bounded scope per PR. Release tooling
  parses them — a break in a published contract ships as `feat!:` or carries a
  `BREAKING CHANGE:` footer, never as a plain `feat:`.
- **Never `--no-verify`.** If a hook blocks, fix the underlying issue.
- **Code, comments, and identifiers in English.** Surgical changes — no opportunistic
  refactors in feature PRs, no suppression comments to silence a linter.
- **Shell scripts** run under `set -euo pipefail` and are idempotent — re-running
  completes what is missing instead of duplicating or destroying.

## Workflow

- Check `docs/adr/` before any structural choice. Branch from `main`.
- **TDD for behavior changes**: red → green → refactor → commit. Bug fixes start with
  a failing regression test. Exception: pure docs, formatting, or copy changes.
- **E2E for key features**: any user-visible change to a primary workflow adds or
  updates a deterministic E2E scenario, isolated from real data and credentials.
  Unit tests do not replace it.
- **ADRs** live in `docs/adr/`, one decision per file, created in the same commit as
  the code (`/create-adr`). Never edit an active ADR — supersede it. Required for a
  new dependency that changes surface area, a storage or schema convention, a core
  abstraction, a hosting or secrets strategy, or a cross-cutting pattern. Not for
  behavior-preserving fixes, refactors, version bumps, or copy tweaks. After a
  structural change, update `docs/ARCHITECTURE.md` in the same commit — it reflects
  **active** decisions only.
- **Destructive actions** — merging, force-pushing, changing repository permissions,
  dropping schema, deleting data — require explicit human sign-off in the moment.
  An agent that hits this gate hands off to the user rather than routing around it.

## Gates

```bash
zig build -Doptimize=ReleaseSafe && zig build test   # build + unit and macOS GUI tests
sentrux check .           # absolute limits (.sentrux/rules.toml)
sentrux gate .            # no structural regression vs .sentrux/baseline.json
```

CI mirrors this: build and tests in `.github/workflows/ci.yml` (macOS runner, AppKit), Sentrux in `.github/workflows/quality.yml`. Before touching existing files run
`sentrux gate --save .` to capture the baseline; before committing run `sentrux gate .`
— degradation on a touched file means refactor, not commit. New files pass
`sentrux check .` clean. **Never silence a rule to pass** — the gate is a ratchet, and
every file you touch leaves with an equal-or-better score.

Done means: gates pass locally, CI is green, no secrets or personal data in the diff,
`README.md` updated if a public contract changed, ADR written if a structural decision
was made.

## agent-belt gotchas

Record every failure that cost real debugging time, with the invariant that prevents
it and a link to the ADR or code that must not be undone. Highest-value part of this
file — keep appending.

- **No `dispatch_once` in C/Objective-C.** Zig compiles C with UBSan in trap mode and
  `dispatch_once`'s inline `DISPATCH_COMPILER_CAN_ASSUME` traps, killing the daemon
  with a bare "trace trap". Use `pthread_once` (`src/agent_switcher.m`, `src/macos_shim.c`).
- **Subprocesses need a locale.** launchd starts the daemon without `LANG`; tmux then
  sanitizes format output and turns every `\t` separator into `_`, so every tmux
  session vanished. `MKRun` sets `LANG=en_US.UTF-8`, and so does the LaunchAgent.
- **A privacy grant is invisible to the process that asked.** `AXIsProcessTrusted`
  stays stale after the user grants Accessibility. Missing permissions make the daemon
  exit and launchd restart it (`mk_check_permissions`), never wait in-process.
- **launchd kills the job's whole process group.** Anything that must outlive the
  daemon (the updater runs `install.sh`, which stops it) is spawned with
  `POSIX_SPAWN_SETSID` (`src/updater.m`).
- **AudioQueue callbacks go to the caller's run loop.** From a dispatch queue (fn+F5)
  there is none and every recording came back empty. `AudioQueueNewInput` gets a
  `NULL` run loop so callbacks use AudioQueue's own thread.
- **The daemon's main thread must run `[NSApp run]`.** A bare `CFRunLoopRun` services
  the event tap but never delivers AppKit events: menu bar clicks, menus, alerts and
  notification actions silently do nothing (`mk_app_run`).
- **The event tap must never block.** Long work (transcription, focus changes, network)
  goes to a queue; the tap only decides and swallows.
- **Orca's CLI does not know the UI focus.** `--worktree active` resolves to the
  caller's cwd and `terminal.resolveActive` returns the first tab. The switcher keeps
  its own position (`~/Library/Caches/agent-belt/last-agent`); never infer focus
  from Orca.
- **Frontmost is not visible.** A minimized or hidden app can be made frontmost with
  every window still in the Dock; unhide and unminimize via Accessibility first
  (`MKRestoreWindows`).
- **Keypad LEDs:** the write is ignored unless `03 FB FB FB` (identify) comes ~300 ms
  before, and every write is persisted to flash, so identical writes are skipped.
  Color 0 is white in reactive mode and off in static mode; modes 2–4 only react to
  key presses. Never send `03 FD`/`03 FC` (key remap, model change). See
  `docs/led-protocol.md`.
- **Keychain: never modify an existing item from a script.** It opens a SecurityAgent
  dialog that blocks the installer with the daemon stopped, and killing `security`
  mid-dialog leaves orphan dialogs. The installer only adds the key when missing.
- **The Mac's microphone key belongs to macOS.** Dictation handles it below the event
  tap; with Dictation off macOS prompts to enable it on every press, and a `hidutil`
  remap does not help. Push-to-talk listens to F5 as apps see it (keycode 96, fn+F5).
- **Claude Code transcripts repeat usage per content block.** Deduplicate by
  `message.id` or tokens and cost multiply (`src/agent_stats.m`).
- **The app name has a space.** Quote every path in `install.sh`
  (`"$(mktemp -d)/Agent Belt.app"`).
- **Agent status comes from the terminal title.** Claude Code writes `✳ title` when
  idle and a spinner (◐◓◑◒, braille) while working; "finished" is a working→idle
  transition seen by the 5 s monitor.
- **Windows: MSYS2's tmux refuses a native console** ("open terminal failed: not a
  terminal"), in Windows Terminal or conhost alike. Attaching runs it under
  `script -qfc … /dev/null`, which gives it a pty (`src/sessions/local.zig`).
- **Windows: the tray daemon opens terminals with `CreateProcessW` +
  `CREATE_NEW_CONSOLE`**, which the default terminal hosts. `wt.exe` is an app
  execution alias; started from the daemon (spawn or ShellExecute) it opens no tab.
- **Windows: an ssh logon has no credential vault.** `CredWriteW` fails with 1312, so
  `agb install` over ssh leaves the Deepgram key in `%LOCALAPPDATA%\agent-belt` and the
  daemon moves it into Credential Manager on its first start.
- **Hyprland: `wtype` loses the first key** while the compositor takes its keymap
  ("Olá" arrived as "lá"); it runs with `-s 120`. `notify-send -r` only replaces an
  id that exists, so the id printed by `-p` is kept in `$XDG_RUNTIME_DIR`. A dmenu
  prompt for free text gets no lines, or Enter picks an empty entry
  (`src/linux/desktop.zig`).
- **Omarchy configures Hyprland in Lua** (`hyprland.lua`, `o.bind`), and Lua binds show
  in `hyprctl binds` as dispatcher `__lua` with a numeric arg: check them by
  description. Its bar only takes plugin widgets through `omarchy bar put`; a command
  module goes straight into `shell.json`. From ssh, the session environment comes from
  `systemctl --user show-environment` (Hyprland's own environ lacks WAYLAND_DISPLAY).
- **Windows: `ssh.exe` never exits when its stdout is a pipe inside an ssh session**
  (it prints the output, then hangs). Remote calls from Windows capture through
  temporary files (`sys.runCaptured`); otherwise `agb ls` over ssh hangs forever.
- **Windows: only a scheduled task (`schtasks /it`) reaches the desktop session from
  ssh**, and a running `.exe` can be renamed but not overwritten: `agb deploy` renames
  `agb.exe` aside and swaps `agent-belt.exe` in before restarting it.

---

Adapted from [Marcos Hernanz](https://x.com/MarcosHernanz/status/2083954734487212511).
Structural gate by [Sentrux](https://github.com/sentrux/sentrux).
`CLAUDE.md`, `GEMINI.md`, `CURSOR.md` and `AGENT.md`
are symlinks to this file — edit `AGENTS.md` only.
