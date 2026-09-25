# Security Policy

## Reporting a vulnerability

Report privately through GitHub:
[**Report a vulnerability**](https://github.com/feliperun/agent-belt/security/advisories/new)
(Security → Advisories on the repository). Please do not open a public issue for
something exploitable.

Include what you can: the version (`agb version`), the platform, and the smallest
sequence that reproduces it. You should get a first answer within a week. This is a
small project run by volunteers: there is no bounty, and fixes ship in the next
release rather than on a fixed schedule.

Supported: the latest release. Older tags get no backports — `agb update` builds the
newest one from source.

## What Agent Belt trusts

Agent Belt runs coding agents on your machines and moves instructions between them.
It is worth being explicit about the boundaries it assumes, because several of them
are wider than they look.

### The machine mesh is one trust domain

`~/.config/work/hosts.conf` lists the machines that can reach each other. Any machine
in that file can, over ssh to your account:

- create an agent session here (`agb _run`), which starts Claude Code with
  `--dangerously-skip-permissions` or Codex with
  `--dangerously-bypass-approvals-and-sandbox`;
- type into a running agent (`agb _send`), read its screen (`agb _peek`) and kill its
  session (`agb _stop`);
- stop a loose agent process and reopen its conversation (`agb _adopt-do`).

None of this exceeds what an ssh login to the same account already allows — the
protocol grants no new power — but it does mean **one compromised machine in the mesh
reaches every agent on every other machine**. Register only machines you administer.

The registry is also an input, not just configuration: `agb deploy` overwrites
`hosts.conf` on each machine it installs to. Entries whose name or `user@host`
destination is not a plain name are dropped when the file is read, so a registry
cannot turn into ssh options.

### ssh keys and host keys

Authentication is your own ssh setup — keys, agent, `~/.ssh/config`. Agent Belt never
handles a private key. `scripts/mesh-keys.sh` distributes *public* keys and repairs
stale `known_hosts` entries.

Connections use `StrictHostKeyChecking=accept-new`: the first host key seen for a
machine is accepted and recorded, and a **changed** key afterwards is refused. Someone
who can answer for a machine's name before you ever connect to it can become that
machine. If that matters to you, seed `~/.ssh/known_hosts` yourself before running
`agb hosts discover` or `agb deploy`.

### The agents themselves

Sessions start with the agent's permission prompts disabled, and the worktree is
marked trusted in Claude Code's `~/.claude.json` and Codex's `config.toml` before the
agent runs — otherwise an autonomous session stops at a dialog nobody is watching.
`WORK_NO_AUTOTRUST=1` turns the trust writes off; each file is backed up to
`<file>.pre-agb.bak` before the first change. Treat an agent session as a shell on
that machine, because that is what it is.

### What leaves your machines

| To | What | When |
|---|---|---|
| Deepgram | microphone audio, and the transcript back | while a dictation key is held |
| DeepSeek (`api.deepseek.com`) | the transcribed request | creating an agent by voice, when a key is configured |
| Jev (`api.typesafe.ai`) | the transcribed request and your machine and repository *names* | creating an agent by voice, when names were not matched exactly |
| GitHub | nothing but the request | the six-hourly release check |
| a sender you configure | the session title | an agent has waited 3 min while the Mac is idle |

No telemetry, no analytics, no crash reporting. Recordings and transcripts stay on the
machine, owner-readable only, for 60 days — `~/Library/Application Support/agent-belt`
on macOS, `~/.local/share/agent-belt` (or `$XDG_DATA_HOME`) on Linux,
`%LOCALAPPDATA%\agent-belt` on Windows. `agb history` lists them.

### Secrets on disk

API keys live in the login Keychain on macOS and in Credential Manager on Windows. On
Linux, and for the Windows fallback described in the README, they are files with mode
`0600` under `~/.config/agent-belt`. Anyone who can read your home directory can read
them; Agent Belt does not defend against a local attacker who is already you.

### Updates

`agb update` downloads the source tarball of a release tag from GitHub over HTTPS and
builds it locally with `./install.sh`. Integrity rests on TLS to `github.com` and on
GitHub itself — releases are not signed, so anyone who can publish a release in this
repository can run code on a machine that updates. The zipped app attached to a
release is never executed by the updater.

## Out of scope

- A local attacker already running as your user.
- Anything an agent decides to do once it is running: Agent Belt starts agents, it
  does not sandbox them.
- Compromise of the agent vendors, Deepgram, DeepSeek, Jev, GitHub or your tailnet.
