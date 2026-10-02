# Agent sessions on any machine

`agb` creates and manages persistent agent sessions: a git worktree, a tmux session and
an agent (Claude Code, Codex or a shell) inside, on any machine of your tailnet. Closing
the terminal, losing the connection or disconnecting RDP kills nothing; attaching again
resumes. The list of live sessions always covers every machine, wherever you are.

The engine is part of `agb` itself (`src/sessions/`, Zig) and runs the same on macOS,
Linux and Windows. It used to be a bash tool called `work`; the registry file and the
tmux marks it wrote are still read.

## Commands

```
agb new [claude|codex|deepseek|zcode|fx|shell] [machine|here] [repo] [what to do…]
agb sessions                      live list across all machines: open, close, rename, screen
agb sessions list                 the list as text, then the number of the session to open
agb sessions open|close|rename    the same actions without the list
agb ls                            the list as text: state, age, tokens, cost, summary
agb repos [machine]               the repository names agb new accepts there
agb attach [-d] <session> [machine]
agb send <session> [machine] <text…>     type an instruction into the agent
agb peek <session> [machine] [lines]     read the end of its screen
agb stop <session> [machine]
agb rename <session> [machine] <new name…>   in tmux and, when idle, in the agent (/rename)
agb adopt [machine]               reopen an agent started outside tmux inside tmux
agb hosts [show|discover|add|rm|self]
agb doctor                        test ssh, agb and the toolchain on every machine
agb deploy <machine…|--all>       build and install agb on other machines
agb tm [name]                     a plain tmux session, no worktree or agent
```

`agb new` reads its words in order, and every part is optional:

| Word | Meaning | Default |
|---|---|---|
| agent | `claude`, `codex`, `deepseek`, `zcode`, `fx` or `shell` | `claude` |
| machine | a registry name, a unique prefix, a dash-separated part (`windows` for `windows-pc`), or `here` | this machine |
| repo | a repository name on that machine (checked by asking it) or a path | the repo this terminal is in; none elsewhere |
| what to do | the agent's first prompt; its first words also name the task | none |

```sh
agb new                                          # claude here, in this repo (task "claude")
agb new codex windows web-app fix the login       # task fix-the-login, prompt "fix the login"
agb new shell linux-box api --task scratch --detach
agb new create an agent on windows with codex in web-app to look into the login
```

A sentence that starts with a verb, in English or Portuguese (`create`, `crie`, `open`,
`abra`, `start`, `inicie`…), is read like the create-agent panel reads speech
(`agb _intent`: exact names in code, the rest decided by Jev), then checked like any other
input.

Without a repo (research, a first sketch) the agent works in `~/agents/<task>`: a plain
directory, no worktree or branch, kept after the session. That is what happens on another
machine when no repo is named, outside a repo here, or with `--no-repo`.

Flags, anywhere: `--agent`, `--host`, `--repo`, `--no-repo`, `--task`, `--prompt`, `-d` (detach other
clients when attaching), `--detach` (create and print the session name instead of
attaching: for scripts and orchestrators), `--dry-run` (print the plan).

### Orchestrating from scripts or another agent

```sh
s=$(agb new codex linux-box api --detach --prompt "run the tests and fix failures")
agb peek "$s" 40          # what the agent shows now
agb send "$s" "also update the changelog"
agb stop "$s"
```

The machine is optional in `send`/`peek`/`stop`: `agb` finds the session.

## What a session is

`agb new … web-app fix-login` on a machine creates, next to the repository:

- the worktree `web-app-fix-login` on branch `work/fix-login` (reused if it already is a
  worktree of that repo; refused if the path is something else);
- the tmux session `web-app-fix-login`, marked with `@work_agent` and `@work_task`;
- the agent started inside it, already trusting the worktree (Claude Code's
  `~/.claude.json`, Codex's `config.toml`; `WORK_NO_AUTOTRUST=1` turns this off).
  A worktree that already had a Claude conversation continues it (`WORK_NEW=1` starts over).

Asking for a task that already has a session attaches to it; a new prompt is typed into
the running agent.

One session, one name. `/rename` in Claude Code or Codex renames the tmux session to
the same name within a listing (15 s): Claude Code's record of its process carries the
name it was given, Codex shows its thread name as the terminal title. `agb rename`
goes the other way, renaming the tmux session and typing `/rename` into the agent when
it is idle at its prompt. `@agb_name` keeps the name last taken from the agent, so a
session renamed on purpose stays so until the agent's name changes again; the old name
stays in `@work_task`, which `agb attach` and `agb new` still find. A name the agent
gave on its own (Claude names conversations as the work goes) does not rename anything,
and neither does a shell's title. DeepSeek, ZCode and fx expose no name.

| Agent | Command |
|---|---|
| claude | `claude --dangerously-skip-permissions --name <task>` (or `--continue`) |
| codex | `codex --dangerously-bypass-approvals-and-sandbox` |
| deepseek | `dsh --profile headless "<prompt>"`, then a shell in the same pane (DeepSeek Harness has no terminal UI; a prompt is required) |
| zcode | `zcode`; tmux types the first prompt once its screen is drawn |
| fx | `fx`; tmux types the first prompt once its screen is drawn |
| shell | `$SHELL` (on Windows, MSYS2's `bash -l`) |

## Machines

The registry is `~/.config/work/hosts.conf` (`%USERPROFILE%\.config\work\hosts.conf` on
Windows):

```
host macbook     alice@macbook      posix
host windows-pc  alice@windows-pc   msys
host linux-box   alice@linux-box    posix
self macbook
```

`agb hosts discover` fills it from `tailscale status` (ssh user from `~/.ssh/config`,
kind from the OS). This machine is found through `WORK_SELF`, the `self` line, the
tailnet name, then the hostname.

Machines talk to each other by running `agb` over ssh (`agb _ls-raw`, `_run`, `_probe`,
`_repos`, `_send`, `_peek`, `_stop`, `_adopt-list`, `_adopt-do`): `~/.local/bin/agb` on
macOS and Linux, `C:\Users\<user>\.local\bin\agb.exe` on Windows, whose sshd hands
commands to PowerShell (arguments are quoted for it). A machine that does not answer
shows up as such in `agb ls`.

`agb deploy <machine…|--all>` builds `agb` for each machine's OS and CPU from this
checkout (static musl on Linux, `x86_64-windows-gnu` on Windows), copies it with the
registry (its own `self` line) and, on Windows, adds `~\.local\bin` to the user's PATH.
`scripts/mesh-keys.sh` makes every machine able to ssh into every other one.

## The session list

`agb sessions` opens at once on the last listing, which `agb` keeps in
`<cache>/agent-belt/sessions.snapshot` whenever any listing runs (the Mac daemon, the
Windows tray and the Omarchy bar list every machine every 15 s), then refreshes every
5 s in the background. Each row shows the machine, session, agent, state (working,
waiting for you, idle), age, and for Claude Code the tokens and cost of the
conversation, its subagents included; below the list, the selected session's folder and
recap (the summary Claude writes when you step away, else your last prompt).

| Key | Action |
|---|---|
| ↑ ↓ (j k), Home End (g G) | select |
| Enter | open it; detaching comes back to the list |
| x | close it (asks first) |
| r | rename it, in tmux and in the agent |
| p | show the end of its screen |
| R, q | refresh now, quit |

Tokens and cost come from the transcript (`~/.claude/projects/*/<id>.jsonl`), read
once and then only from where the last reading stopped: the position and the sums are
cached in `<cache>/agent-belt/transcripts/`, so a transcript of hundreds of megabytes
costs its new lines only. Prices are the same table as the Mac menu's.

## Windows

tmux is MSYS2's (`C:\msys64\usr\bin\tmux.exe`); `agb.exe` runs it through MSYS2's login
bash, which provides its runtime and paths. Git and the agents are native: repositories
live under `C:\dev` (`WORK_REPOS_DIR` overrides), paths are converted between `C:\…`
and `/c/…` as each tool expects, and native agents run under `winpty` inside the pane.
MSYS2's tmux does not accept a native console as a terminal, so `agb attach` runs it
under `script`, which provides a pty.

From another machine, `agb attach` reaches a Windows session through MSYS2's sshd,
which the tray keeps running on `127.0.0.1:58022` and `agb deploy` sets up: the client
jumps through Windows' sshd (`ssh -J`) and runs tmux on a real MSYS2 pty. Windows' own
sshd re-renders the screen through a pseudo console and stalled typing for seconds
while an agent drew; it stays the fallback when the MSYS2 sshd does not answer
([ADR 0007](adr/0007-attach-to-windows-through-msys2-sshd.md)).

`agb deploy` also installs `agent-belt.exe`, the tray daemon (see the README's Windows
section): its menu lists these sessions and opens them in a terminal window.

## Adopting an agent started outside tmux

A Claude Code or Codex process started directly in a terminal cannot be attached, but
its conversation lives on disk. `agb adopt` lists them (on macOS and Linux), stops the
chosen one and reopens **that exact conversation** inside tmux (`claude --resume <id>`,
`codex resume <id>`). The id comes from the process's own arguments, from
`~/.claude/sessions/<pid>.json` or from the rollout file Codex keeps open; when it cannot
be established, adopt refuses rather than falling back to "the latest conversation here",
which can belong to another agent and leaves two processes fighting over one conversation.
The turn in progress and the scrollback are lost.

A Claude Code or Codex that cmux's hooks recorded, running in a cmux tab outside tmux, can
also be adopted from the menu bar: **Adopt into tmux** lists them, asks first, and then runs
the same adoption and types `agb attach` into the tab the agent ran in, so the tab now holds
the session and the agent shows up in `agb ls` and on every machine.
