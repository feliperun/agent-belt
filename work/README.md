# work — persistent work sessions across the whole tailnet

In Agent Belt, these commands are reached through `agb` (`agb sessions`, `agb ls`, `agb attach`, `agb hosts`, `agb doctor`, `agb adopt`, `agb tm`, `agb deploy`, `agb new --task …`).

Each task gets an isolated **git worktree**, a **tmux session** and an **agent**
(Claude Code or Codex) running inside it. Closing the terminal, losing the connection or
disconnecting RDP kills nothing — running `work` again reattaches.

A session can be created on **any machine in the tailnet, from any
other**, and the list of live sessions is always the list across *all* machines,
regardless of where you are and which directory you're in.

```
work                            interactive menu with the sessions of every machine
work ls                         the same list, as text
work <task> [repo]              create (or reattach) here
work <machine> <task> [repo]    create (or reattach) on that tailnet machine
work attach <session> [machine] attach directly, no menu
work adopt [machine]            adopt an agent opened outside tmux
work hosts [discover|add|rm|self]   machine registry
work doctor                     test ssh, work and toolchain on every machine

  -a|--agent claude|codex|shell   which agent starts (default: claude)
  -p|--prompt "text"              first instruction for the agent (typed into it if the session exists)
  --codex / --claude / --shell    shortcuts
tm [name]                         plain tmux session, no worktree or agent
```

`work xpto` inside `~/dev/micromed/coreum` creates the worktree `coreum-xpto` on
branch `work/xpto` and the tmux session `coreum-xpto`. `work frb-omarchy xpto coreum`
does the same on omarchy — and if you are inside a git repo, the repo's **name**
travels along, so `work frb-omarchy xpto` resolves `coreum` to the copy over there.

Machines are identified by their **official tailnet name** (`macbook-pro`,
`felipe-windows`, `frb-omarchy`, …). An unambiguous prefix also works:
`work frb-om xpto`.

## Architecture

A single script, `bin/work`, installed on **every** machine — each one is
client and host at the same time. When the target is itself, it runs locally; when
it's another, it calls that machine's `work` over ssh. The session is always created by
the target machine's `bin/work-session`, which resolves PATH, worktree, agent
trust and tmux using its own platform's rules.

```
bin/work          dispatcher: registry, menu, ls, attach, doctor
bin/work-session  creates/reattaches the session on this machine (macOS, Linux, MSYS2)
bin/tm            plain tmux session
windows/…ps1      PowerShell work/tm/works functions (they call MSYS2's bash)
install.sh        installs into ~/.local/bin on this machine
scripts/deploy.sh installs/updates the machines in the registry
scripts/mesh-keys.sh   distributes ssh keys so every machine can reach every other
```

### Machine registry

`~/.config/work/hosts.conf`, one line per machine:

```
host macbook-pro     frb@macbook-pro           posix
host felipe-windows  Micromed@felipe-windows   msys
host frb-omarchy     frb@frb-omarchy           posix
self macbook-pro
```

`work hosts discover` fills this in from `tailscale status` (the ssh user
comes from each host's `~/.ssh/config`, and the type from the OS reported by the
tailnet). `deploy.sh` **copies** this registry to the other machines instead
of rediscovering there: rediscovering on the other side gets the user wrong for hosts that aren't in
that machine's `~/.ssh/config` — `Micromed@felipe-windows` would become `frb@felipe-windows`.

### Clipboard when attaching to a remote session

With `work attach` the session stays in the target machine's tmux, but the
terminal is on the originating client. `work` automatically configures the target's
tmux to forward the clipboard via OSC 52: it enables `set-clipboard`,
`allow-passthrough` and the generic `*:clipboard` feature before creating or
attaching to the session. This matters especially for an Omarchy terminal with
a session on macOS, because macOS's tmux doesn't know `xterm-ghostty` by
default.

After updating `work`, just attach again with `work attach`. In tmux
copy-mode, `v` starts the selection and `y` copies to the local clipboard.

## Installation

**On one machine** (macOS, Linux or Windows with MSYS2):

```
./install.sh
```

Copies `work`, `work-session` and `tm` to `~/.local/bin` (plus the `rwork` alias),
discovers the tailnet machines and marks which one this is. On Windows it also installs the
PowerShell profile.

**On the others, from one that is already installed:**

```
./scripts/deploy.sh --all          # ou: ./scripts/deploy.sh frb-omarchy felipe-windows
```

**Everyone-to-everyone ssh keys** (which lets you create a session in any
combination of origin and target):

```
./scripts/mesh-keys.sh --dry-run   # mostra o que faria + a matriz de quem alcança quem
./scripts/mesh-keys.sh             # corrige e mostra a matriz
```

It handles **both** reasons that break a pair:

1. `authorized_keys` missing the origin's key → `Permission denied (publickey)`.
   Which keys to distribute can't be found by listing `~/.ssh/*.pub`: the
   `~/.ssh/config` may force a different `IdentityFile` per target. The one that
   knows the answer is the origin's ssh, so the script runs
   `ssh -G <target>` there and uses exactly what it says it will offer.
2. `known_hosts` with an old host key → `HOST IDENTIFICATION HAS CHANGED`, which
   refuses the connection *before* authenticating. It happens when a machine is
   reinstalled. The reference is the `known_hosts` of whoever runs the script (which
   reaches all of them); only when there's no local record does the key come from `ssh-keyscan`.

A machine that's down is simply skipped — run it again when it comes back.

Windows is left out of the automatic writes: there the account is an administrator and
sshd uses `C:\ProgramData\ssh\administrators_authorized_keys`, with an ACL restricted to
SYSTEM + Administrators — `ssh-copy-id` hits the wrong file and fails
silently. Since Windows already accepts the other machines, the script only reports.

**Windows, prerequisites** — MSYS2 with tmux and winpty, Git for Windows, Node and
`claude.exe`:

```powershell
winget install --id MSYS2.MSYS2 -e
C:\msys64\usr\bin\bash.exe -lc "pacman -Sy --noconfirm --needed tmux winpty"
```

## Agents

| agent | how it starts |
|---|---|
| `claude` (default) | `claude --dangerously-skip-permissions --name <task>` |
| `codex` | `codex --dangerously-bypass-approvals-and-sandbox` |
| `shell` | just `$SHELL` in the worktree, no agent |

Both stop at a trust dialog when opening a new directory — and every
worktree is a new directory, which would kill the autonomous session before it starts.
Since the worktree is a checkout of a repo you chose yourself, `work-session`
pre-authorizes it: `hasTrustDialogAccepted` in `~/.claude.json` for Claude,
`[projects."<path>"] trust_level = "trusted"` in Codex's `config.toml`
(respecting `CODEX_HOME`). `WORK_NO_AUTOTRUST=1` turns it off.

The chosen agent is tagged on the session (`@work_agent`) and shows up in the
AGENTE column of `work ls`.

**Renaming the conversation in the agent renames the tmux session.** Claude Code (and
Codex) publish their own name in the terminal title, and that's what tmux
stores in `pane_title` — the only channel that exists from inside the agent to
the outside. So `/rename` there shows up in `work` here. Three caveats along the way:

- the title comes with a status glyph in front (`✳ fix-windows`), so only the
  part that becomes a slug counts;
- if the agent's name is the same one `work` passed in `--name`, there's no rename
  to propagate (it would swap `coreum-xpto` for `xpto` and lose the repo from the name);
- the repo prefix stays: `coreum-xpto` renamed to `bug-impressora` becomes
  `coreum-bug-impressora`.

The old name keeps working (`work xpto` finds the renamed session) because
the lookup uses the `@work_task` tag, not the name. `WORK_NO_RENAME=1` turns it off. A session that was **not** created by `work` — including a tmux
you opened by hand — also shows up in the list, with the agent inferred from the
pane's foreground process and a `~` indicating it's an inference.

### What the list says besides the sessions

```
5 maquinas: 1 com sessao, 4 sem, 1 sem resposta: frb-linux  ->  work doctor
agente fora do tmux, aberto direto (nao da para atachar): felipe-windows (1)
```

Without this footer you can't tell "this machine has no session" from "this
machine didn't respond" — and you end up looking for a session the list will never
show. The `ls-raw` response ends with a `#fora` line, which serves as a
sign of life: if it didn't arrive, the machine is listed as *no response*.

### Adopting an agent opened outside tmux

A console process **doesn't migrate** into tmux once it has started: on
Linux there's `reptyr`, which is fragile with TUIs, and on Windows there's no equivalent — the
process is bound to the ConPTY of the window that created it. But the *conversation* doesn't live
in the process: Claude stores each session in
`~/.claude/projects/<path>/<id>.jsonl` and Codex in `~/.codex`. So you can
end the stray process and reopen the same conversation inside tmux:

```
work adopt                  # candidates on every machine
work adopt felipe-windows   # só naquela
```

```
  #  MAQUINA           AGENTE   ATIVO  CONVERSA   DIRETORIO
  1  felipe-windows    claude      3h  +recente   /c/dev/faberun-fix-windows
```

Once one is chosen, it asks for confirmation, ends the process and starts a tmux session
in the same directory with `--continue` (or `--resume <id>`, when the id is in the
process's arguments — then the resumed conversation is exactly that one, with no
ambiguity when there are several agents in the same directory). You lose the turn in
progress and the scrollback; the conversation comes back whole.

On Windows the directory doesn't come from the process (msys can't read the cwd of a native
process): it comes from the `"cwd"` recorded in the conversation's own `.jsonl`, unescaped and
converted to the form tmux understands.

## Why Windows is different

It's not WSL on purpose: on a machine with virtualization turned off and
Windows-native repos in `C:\dev`, access through `/mnt/c` would be slow and without a toolchain.
The multiplexer is MSYS2's tmux and the agent stays native. Hence four
adaptations, all commented in the code:

1. **`winpty` in front of the agent** — without it Node doesn't find a real
   console inside the pane and the TUI doesn't enter raw mode.
2. **PATH built by hand** — the MSYS2 login shell is minimal and doesn't see `git`,
   `node` or `claude`.
3. **Collision guard** — `$repo-$task` can clash with a real neighboring repo
   (`coreum` → `coreum-docs` exists). A pre-existing directory is only reused
   if it really is a worktree of that repo. Applies on all platforms.
4. **Worktree pre-authorization**, above.

## Known pitfalls

- **Windows sshd wraps the command in `powershell -c`.** Shell quoting
  is worthless there: double quotes vanish, `\ ` doesn't escape a space, `||` becomes a syntax
  error. That's why `work` sends only simple tokens there (and validates the
  arguments as slugs instead of escaping them), `deploy.sh` uses plain PowerShell
  without quotes to create directories, and `mesh-keys.sh` sends scripts over **stdin**
  (`bash -l -s`) when it needs quotes.
- **`bash -s` without `-l` on MSYS2** doesn't even have `/usr/bin` on PATH: `uname`, `tr`
  and `head` vanish. Always `-l -s`.
- **Backslashes are rejected in arguments**: use `coreum` or
  `C:/dev/coreum`, never `C:\dev\coreum`.
- **No control characters in tmux formats.** `ls-raw` separates fields
  with `|`: under the C locale tmux replaces non-printables with `_` in `-F` output, and
  only on the remote target — the field disappears and the whole line gets misaligned.
- **Tab doesn't work as a separator either**: bash's `read` collapses runs
  of whitespace, and an empty field shifts all the others.
- **`tmux set-option -t` doesn't accept the `=` prefix** for an exact target (but
  `attach`/`has-session` do), and a `-s` in its place would become a *server option* —
  it would tag every session at once.
- **Shell functions shadow PATH**: `work` and `tm` used to be functions in `.zshrc`;
  they became scripts precisely so they behave the same on every machine.
- **`bash -s` reading a script from stdin can also be used to send data**: the
  `while read` after `done` consumes the rest of the same stdin. That's how
  `mesh-keys.sh` delivers a script *and* a list to Windows, where a quoted argument
  doesn't survive `powershell -c`.
- **PowerShell output comes with CRLF**: `grep -x OK` fails silently without
  a `tr -d '\r'` first — it gives a false negative in connectivity tests.
- **`IdentitiesOnly yes` with a fixed `Host` list doesn't cover a new machine.** On
  Windows the tailnet block in `~/.ssh/config` points to a key without a
  passphrase; a host outside that list falls back to the default `id_ed25519`, which *has* a
  passphrase and doesn't open in `BatchMode` — `Permission denied (publickey)` even
  with the right key authorized on the target. When registering a new machine,
  add its name to that `Host`.
- **Windows `ssh` is not on the MSYS2 login shell's PATH**
  (`/c/Windows/System32/OpenSSH`). Without it the machine works as a host but
  not as a client: remote calls fail silently and `work ls` shows only
  the local sessions.
