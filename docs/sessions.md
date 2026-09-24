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
agb new [claude|codex|shell] [machine|here] [repo] [what to do…]
agb sessions                      interactive picker across all machines
agb ls                            the same list, as text
agb repos [machine]               the repository names agb new accepts there
agb attach [-d] <session> [machine]
agb send <session> [machine] <text…>     type an instruction into the agent
agb peek <session> [machine] [lines]     read the end of its screen
agb stop <session> [machine]
agb adopt [machine]               reopen an agent started outside tmux inside tmux
agb hosts [show|discover|add|rm|self]
agb doctor                        test ssh, agb and the toolchain on every machine
agb deploy <machine…|--all>       build and install agb on other machines
agb tm [name]                     a plain tmux session, no worktree or agent
```

`agb new` reads its words in order, and every part is optional:

| Word | Meaning | Default |
|---|---|---|
| agent | `claude`, `codex` or `shell` | `claude` |
| machine | a registry name, a unique prefix, a dash-separated part (`windows` for `felipe-windows`), or `here` | this machine |
| repo | a repository name on that machine (checked by asking it) or a path | the repo this terminal is in; none elsewhere |
| what to do | the agent's first prompt; its first words also name the task | none |

```sh
agb new                                          # claude here, in this repo (task "claude")
agb new codex windows coreum fix the login       # task fix-the-login, prompt "fix the login"
agb new shell linux2 mac-debian --task scratch --detach
agb new create an agent on windows with codex in coreum to look into the login
```

A sentence that starts with a verb (`create`, `crie`, `open`, `start`…) is read like the
create-agent panel reads speech (`agb _intent`: exact names in code, the rest decided by Jev),
then checked like any other input.

Without a repo (research, a first sketch) the agent works in `~/agents/<task>`: a plain
directory, no worktree or branch, kept after the session. That is what happens on another
machine when no repo is named, outside a repo here, or with `--no-repo`.

Flags, anywhere: `--agent`, `--host`, `--repo`, `--no-repo`, `--task`, `--prompt`, `-d` (detach other
clients when attaching), `--detach` (create and print the session name instead of
attaching: for scripts and orchestrators), `--dry-run` (print the plan).

### Orchestrating from scripts or another agent

```sh
s=$(agb new codex linux2 mac-debian --detach --prompt "run the tests and fix failures")
agb peek "$s" 40          # what the agent shows now
agb send "$s" "also update the changelog"
agb stop "$s"
```

The machine is optional in `send`/`peek`/`stop`: `agb` finds the session.

## What a session is

`agb new … coreum fix-login` on a machine creates, next to the repository:

- the worktree `coreum-fix-login` on branch `work/fix-login` (reused if it already is a
  worktree of that repo; refused if the path is something else);
- the tmux session `coreum-fix-login`, marked with `@work_agent` and `@work_task`;
- the agent started inside it, already trusting the worktree (Claude Code's
  `~/.claude.json`, Codex's `config.toml`; `WORK_NO_AUTOTRUST=1` turns this off).
  A worktree that already had a Claude conversation continues it (`WORK_NEW=1` starts over).

Asking for a task that already has a session attaches to it; a new prompt is typed into
the running agent. Renaming the conversation in the agent renames the tmux session (the
agent publishes its name as the terminal title), keeping the repo prefix.

| Agent | Command |
|---|---|
| claude | `claude --dangerously-skip-permissions --name <task>` (or `--continue`) |
| codex | `codex --dangerously-bypass-approvals-and-sandbox` |
| shell | `$SHELL` (on Windows, MSYS2's `bash -l`) |

## Machines

The registry is `~/.config/work/hosts.conf` (`%USERPROFILE%\.config\work\hosts.conf` on
Windows):

```
host macbook-pro     frb@macbook-pro           posix
host felipe-windows  Micromed@felipe-windows   msys
host frb-linux       frb@frb-linux             posix
self macbook-pro
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

## Windows

tmux is MSYS2's (`C:\msys64\usr\bin\tmux.exe`); `agb.exe` runs it through MSYS2's login
bash, which provides its runtime and paths. Git and the agents are native: repositories
live under `C:\dev` (`WORK_REPOS_DIR` overrides), paths are converted between `C:\…`
and `/c/…` as each tool expects, and native agents run under `winpty` inside the pane.
MSYS2's tmux does not accept a native console as a terminal, so `agb attach` runs it
under `script`, which provides a pty.

`agb deploy` also installs `agent-belt.exe`, the tray daemon (see the README's Windows
section): its menu lists these sessions and opens them in a terminal window.

## Adopting an agent started outside tmux

A Claude Code or Codex process started directly in a terminal cannot be attached, but
its conversation lives on disk. `agb adopt` lists them (on macOS and Linux), stops the
chosen one and reopens the same conversation inside tmux (`--resume <id>` when the
process carries it, otherwise `--continue`). The turn in progress and the scrollback are
lost.
