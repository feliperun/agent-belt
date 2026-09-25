# Review: local data and secrets

How agent-belt stores, reads, logs and deletes secrets (the Deepgram, DeepSeek
and Jev keys) and private user data (voice, transcripts, spoken prompts) on
macOS, Linux and Windows. Every finding is a requirement: what is wrong, how it
is triggered, what was changed and the command that proves it.

Scope of this pass: `src/history.zig`, `src/linux/`, `src/windows/`,
`src/daemon.zig`, `src/create_agent.zig`, `src/live_recording.zig`,
`src/wav_stream.zig`, `src/sessions/sys.zig`, `src/macos.zig`, `src/system.m`,
`src/create_panel.m`, `src/status_item.m`, `src/macos_shim.*`, `install.sh`.

## Findings

### LDS-1. Linux runtime files land in a world-writable /tmp
- **severity:** critical
- **where:** src/linux/desktop.zig:175 (`runtimeFile`), used by src/linux/agent_panel.zig and src/wav_stream.zig
- **evidence:** `XDG_RUNTIME_DIR orelse "/tmp"` put every runtime file under
  fixed names in a directory every local user can write: `/tmp/agb-ptt.wav`
  (the recording), `/tmp/agb-ptt.final` and `/tmp/agb-agent.state` (the
  transcript and the whole request), `/tmp/agb-overlay.qml` and
  `/tmp/agb-agent.qml` (the QML quickshell runs), `/tmp/agb-ptt.pid` and
  `/tmp/agb-menu.pid`, `/tmp/agb-agent.cmd` (the panel's commands). A session
  without XDG_RUNTIME_DIR (a plain `ssh` login, a service unit, a compositor
  started by hand) is enough to trigger it. Another local user could then read
  the audio and the transcript; pre-create `agb-ptt.wav` or
  `agb-overlay.qml.agb.tmp` as a symlink and have `pw-record` or the rename
  overwrite a file of the victim's, or feed quickshell QML of their own, which
  runs as the victim; write a pid and have `agb` signal an unrelated process;
  or write `agb-agent.cmd` with `{"seq":9,"text":"…","action":"create"}` and
  have the panel open `agb new … --prompt <their text>`, an agent acting on a
  stranger's instructions in the victim's repositories.
- **fix:** `runtimeFile` resolves through `runtimeDir`, which uses
  XDG_RUNTIME_DIR (private to the user by definition) and otherwise creates
  `/tmp/agent-belt-<uid>` through the new `sys.createPrivateDir`: mode 0700,
  and refused — the command fails instead of writing — when the path is not a
  directory (a planted symlink) or is open to the group or to everyone.
- **status:** fixed
- **proof:** command: `bash -c '! grep -q "XDG_RUNTIME_DIR\") orelse \"/tmp\"" src/linux/desktop.zig && grep -q "createPrivateDir" src/linux/desktop.zig && zig test src/sessions/sys.zig'`

### LDS-2. Sixty days of recordings and transcripts readable by every local user
- **severity:** high
- **where:** src/history.zig:91 (`makeDir`), src/history.zig:96 and :108 (WAV and JSON)
- **evidence:** the history directory was created with `createDirPath`
  (0777 & umask → 0755) and both files with the default permissions
  (0666 & umask → 0644). On Linux the store sits in
  `~/.local/share/agent-belt/history`, under a home directory that is 0755 on
  most distributions: any other account on the machine could read every WAV and
  every transcript of the last 60 days. (On macOS `~/Library` is 0700, which
  hid the same mistake.) Triggered by any dictation.
- **fix:** the directory is created 0700 and every WAV and transcript 0600;
  a directory an older version left open is closed again on the next write
  (`makeDir`/`makePrivate`).
- **status:** fixed
- **proof:** command: `zig test src/history.zig` (test "a recording is readable by its owner and by nobody else"; also runs under `zig build test`)

### LDS-3. install.sh hands the Deepgram key to `ps`
- **severity:** high
- **where:** install.sh:32 (`store_key`), install.sh:163 and :167 (the two places a key is stored)
- **evidence:** `security add-generic-password … -w "$DEEPGRAM_API_KEY" -T "$app"`
  put the key in the arguments of the `security` process. On macOS a plain user
  reads the arguments of processes owned by others (`ps -axo user,args` lists
  root's command lines), so any account on the machine polling `ps` during the
  install captures the key. The same held for the key typed at the `read -rsp`
  prompt.
- **fix:** `store_key` feeds the same command to `security -i` on standard
  input, where only this user can look; the key never becomes an argument.
  Values are escaped for the interactive parser (`\` and `"`), verified to
  round-trip exactly.
- **status:** fixed
- **proof:** command: `bash -c '! grep -q "security add-generic-password" install.sh && grep -q "security -i" install.sh && bash -n install.sh'`

### LDS-4. Spoken prompts and caches written readable by everyone
- **severity:** high
- **where:** src/sessions/sys.zig:184 (`writeFileAtomic`)
- **evidence:** every file agb writes through `writeFileAtomic` was created
  0644: the spoken prompt handed to the agent
  (`~/.cache/agent-belt/prompts/<task>.txt`, written by src/sessions/local.zig),
  the name/summary cache of each request (`~/.cache/agent-belt/names/<hash>`),
  the repo index, the Linux Deepgram key file and the panel's state. With a
  0755 home directory this is the request itself, in the clear, for every
  account on the machine. Triggered by creating one agent by voice.
- **fix:** `writeFileAtomic` creates the temporary file 0600, so the rename
  also repairs files an older version left open (`sys.owner_only_file`).
- **status:** fixed
- **proof:** command: `zig test src/sessions/sys.zig` (test "what is written is the owner's alone, and a shared directory is refused")

### LDS-5. The Linux Deepgram key kept a loose mode across installs
- **severity:** medium
- **where:** src/linux/desktop.zig:469 (`install`)
- **evidence:** `agb install` created `~/.config/agent-belt/deepgram.key` with
  `.permissions = .fromMode(0o600)`, which POSIX applies only when the file is
  created. A key file that already existed — left by an earlier version, by
  `echo … > deepgram.key`, or restored from a backup — kept its 0644 and was
  read back happily by `deepgramKey`. Running `agb install` again did not
  repair it.
- **fix:** the key is written through `sys.writeFileAtomic`: a new 0600 file
  and a rename, so every install leaves the key owner-only whatever was there.
- **status:** fixed
- **proof:** command: `bash -c 'grep -q "sys.writeFileAtomic(ctx, path, key)" src/linux/desktop.zig && ! grep -q "fromMode(0o600)" src/linux/desktop.zig'`

### LDS-6. The dictated request written to the daemon log
- **severity:** medium
- **where:** src/create_panel.m:402, src/daemon.zig:118, src/windows/daemon.zig:319
- **evidence:** the macOS create panel logged the whole command it was about to
  run — `agb new --agent … --prompt '<everything that was said>'` — to stderr,
  which launchd appends to `~/Library/Logs/agent-belt.log`; push-to-talk with
  the agent menu open logged `VOICE COMMAND: <text>`; the Windows tray logged
  the full command line of every terminal it opened, `--prompt` included. That
  log is kept for the life of the install (trimmed only past 2 MB), is printed
  by `agb status`, and is what a user pastes when asking for help — while the
  60-day store is the place these words are supposed to live.
- **fix:** the panel logs the session (`🦇 <task> · <agent> @ <host>`), the
  voice command logs its length, and the Windows tray logs the window title.
- **status:** fixed
- **proof:** command: `bash -c '! grep -q "new agent: %s\\\\n\", command.UTF8String" src/create_panel.m && ! grep -q "VOICE COMMAND: {s}" src/daemon.zig && ! grep -q "open: {s}\", .{line.items}" src/windows/daemon.zig'`

### LDS-7. The transcript handed to the notification daemon
- **severity:** low
- **where:** src/linux/desktop.zig:272 (`pttStop`)
- **evidence:** after typing, `notify(ctx, "Agent Belt", text, 1)` sent the
  whole transcript as a notification body with a 1 ms timeout — invisible to
  the user, whose only purpose is to replace the "Listening" bubble, but kept
  by notification daemons that hold a history (mako's `makoctl history`,
  dunst's log) and carried over the session bus.
- **fix:** the replacing notification has an empty body.
- **status:** fixed
- **proof:** command: `bash -c '! grep -q "notify(ctx, \"Agent Belt\", text, 1)" src/linux/desktop.zig'`

### LDS-8. Voice and transcript left in the runtime directory after use
- **severity:** low
- **where:** src/linux/desktop.zig (pttStop), src/linux/agent_panel.zig (collect, host)
- **evidence:** dictation deleted `agb-ptt.wav` but left `agb-ptt.final` (the
  transcript) until the next recording; the agent panel left `agb-agent.wav`
  (the voice), `agb-agent.final` and `agb-agent.state` (the whole request)
  behind when it closed. On a session whose runtime directory is not a tmpfs
  they outlive the request that produced them, outside the 60-day store.
- **fix:** the transcript files are deleted when dictation ends, and the
  panel's WAV, transcript and state when the panel does — the history keeps
  the recording.
- **status:** fixed
- **proof:** command: `bash -c 'grep -q "agb-ptt.final" src/linux/desktop.zig && grep -q "agb-agent.final" src/linux/agent_panel.zig && grep -q "deleteFile(ctx.io, p)" src/linux/agent_panel.zig'`

### LDS-9. The Keychain key left in freed memory, and read after free
- **severity:** low
- **where:** src/macos.zig:34, src/live_recording.zig:67 and :121, src/system.m:151
- **evidence:** `mk_keychain_secret` returns a `malloc`ed copy of the Deepgram
  key; both the C buffer and the Zig copy were handed back to the allocator
  with the key still in them, so it stays in the daemon's heap — and in a crash
  report of a process that runs for weeks. In `agb status` the same pointer was
  tested after `free(secret)` to choose the message, a read of a dangling
  pointer.
- **fix:** the C buffer and the Zig copy are zeroed before being freed
  (`wipe`), and `agb status` keeps the result in a `BOOL` before freeing.
- **status:** fixed
- **proof:** command: `bash -c 'grep -q "@memset(span, 0)" src/macos.zig && grep -q "fn wipe" src/live_recording.zig && grep -q "BOOL readable = secret != NULL" src/system.m'`

### LDS-10. The 60-day retention only ran when a new recording was saved
- **severity:** low
- **where:** src/history.zig:200 (`command`)
- **evidence:** `prune` was called only from the save path. Someone who stops
  dictating keeps every recording for ever, although the product says the
  history is kept for 60 days — the opposite of what a retention promise means.
- **fix:** `agb history` prunes before listing.
- **status:** fixed
- **proof:** command: `bash -c 'grep -q "prune(io, d) catch {}" src/history.zig'`

### LDS-11. `--uninstall` said nothing about the recordings left behind
- **severity:** low
- **where:** install.sh:69
- **evidence:** uninstalling named the config and the Keychain item as kept,
  but not the 60 days of voice and transcripts in
  `~/Library/Application Support/agent-belt/history`, which also stay. Someone
  removing the app to remove its data has no way to know.
- **fix:** the uninstall message names the directory and how to delete it.
- **status:** fixed
- **proof:** command: `bash -c 'grep -q "your recordings and transcripts stay in" install.sh && bash -n install.sh'`

### LDS-12. The dictated request travels in process arguments
- **severity:** medium
- **where:** src/create_panel.m:238, src/linux/agent_panel.zig:201 and :205, src/sessions/cli.zig:426 (`newArgs`), src/linux/desktop.zig:274 (`wtype`)
- **evidence:** the panel runs `agb _intent <the whole request>` and
  `agb _summary <the whole request>` about every 350 ms while the request
  changes, creation runs `agb new … --prompt <the request>`, and Linux
  dictation runs `wtype -s 120 -- <the text>`. Arguments are world-readable in
  `/proc/<pid>/cmdline` on Linux, and on macOS `ps -axo args` shows other
  users' command lines, so any local account polling `ps` collects what was
  dictated.
- **fix:** not changed. Two halves, and they are accepted for different reasons.
  Linux typing is unavoidable: `wtype` and `ydotool type` take the text only as
  an argument, so the only way to keep it out of `ps` is to drop dictation on
  Linux. The `_intent`, `_summary` and `new --prompt` calls could move to the
  shape `src/sessions/intent.zig` already uses — the request in `AGB_TASK`/
  `AGB_REQUEST`, since `/proc/<pid>/environ` is readable only by its owner —
  but that rewrites the panel↔CLI protocol across `src/create_panel.m`
  (AppKit), `src/linux/agent_panel.zig` (Quickshell) and `src/sessions/cli.zig`
  at once. Neither panel has a test and neither can be driven from a review
  run, so a silent mistake there stops agent creation, the product's headline
  feature, for every user. **This half is deferred, not resolved**: it wants a
  node that owns the panels and can exercise them end to end. Until then the
  window is a local account polling `ps` while someone dictates.
- **status:** accepted
- **proof:** command: `grep -q '"wtype", "-s", "120", "--", text' src/linux/desktop.zig`

### LDS-13. The last spoken request kept for ever in ~/Library/Caches, mode 0755
- **severity:** medium
- **where:** src/agent_switcher.m:939-940 (`MKOpenTerminal`)
- **evidence:** without Orca, the create panel opens the agent by writing
  `~/Library/Caches/agent-belt/new-agent.command` — a script containing
  `agb new … --prompt '<everything that was said>'` — and chmods it 0755. It is
  never deleted, so the last request stays on disk indefinitely, executable,
  outside the 60-day store, and readable by anyone who can reach that directory
  (today only the owner, because `~/Library` is 0700 — the file's own mode
  does not protect it).
- **fix:** fixed in the consolidation pass, which owns `src/`. The cache
  directory is created `0700`, the script is written `0700` instead of `0755`,
  and its first line is `rm -f "$0"`, so the request is gone from disk the
  moment Terminal runs it — zsh buffers a two-line script whole before the
  first command executes, so the later lines still run. Verified with a
  throwaway script under `/bin/zsh -l`.
- **status:** fixed
- **proof:** command: `! grep -q 'NSFilePosixPermissions: @0755' src/agent_switcher.m && grep -q 'zsh -l\\nrm -f' src/agent_switcher.m && [ "$(grep -c 'NSFilePosixPermissions: @0700' src/agent_switcher.m)" = 2 ]`

## Checked, no finding

- **Keychain and Credential Manager.** The macOS daemon reads the key through
  `SecItemCopyMatching` with no prompt of its own, and the installer only adds
  a missing item (changing one opens a SecurityAgent dialog that would stall
  the install). Windows stores it with `CredWriteW`; the plaintext fallback
  used when an ssh logon has no vault (`%LOCALAPPDATA%\agent-belt\deepgram.key`,
  protected by the profile ACL) is deleted as soon as the desktop daemon moves
  it into the vault.
- **Keys in logs, notifications and errors.** No path prints a key: `agb status`
  reports only whether it can be read, `agb uninstall` prints the key's path,
  and the Deepgram, DeepSeek and Jev clients put keys in headers only.
  DeepSeek's key is read from the login shell through a pipe, never an argument.
- **Windows temporary capture files.** `sys.runCaptured` writes to
  `%TEMP%\agb-<ns>-<seq>.out/.err`, a per-user directory protected by its ACL,
  and deletes both on every path.
- **The Quickshell IPC.** The overlay and the panel only read the state file
  and write the command file named in `AGB_OVERLAY_STATE`/`AGB_PANEL_CMD`; with
  LDS-1 fixed both live in a directory only their owner can enter, and the
  panel's `agb-agent.lock` keeps a single host per session.
- **The transcript on its way to the clipboard** already goes through the
  environment (`AGB_TEXT`), not the command line, and `~/Library/Caches/agent-belt/daemon.lock`
  is created 0600.
- **Config files.** `~/.config/agent-belt/config.json` holds no secret — only
  the name of the environment variable to read.
