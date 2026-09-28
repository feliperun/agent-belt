---
type: ADR
id: "0007"
title: "Attach to Windows sessions through MSYS2's sshd"
status: active
date: 2026-09-28
---

## Context

Attaching from a Mac or Linux machine to a session on Windows went through Windows'
own sshd, then PowerShell, `agb.exe`, a login bash and `script(1)`, which gives
MSYS2's tmux the pty it needs. Windows' sshd hands every session a pseudo console
(ConPTY), which parses what tmux draws and renders it again.

Measured from a Mac, typing into a shell pane while another pane redrew 40 lines at
30 frames per second (what an agent's screen does):

| Path | median | p90 | max |
|------|--------|-----|-----|
| Windows' sshd (`agb attach`) | 17 ms | 1730 ms | 2727 ms |
| MSYS2's sshd, through a jump | 29 ms | 43 ms | 131 ms |
| Linux, for reference | 14 ms | 29 ms | 49 ms |

Every other key waited seconds on Windows' sshd; PowerShell and `agb.exe` made no
difference (the same 94 ms echo at rest without them).

## Decision

A Windows machine runs a second sshd, MSYS2's (`src/sessions/msys_ssh.zig`):

1. **Setup:** `agb install` and `agb deploy` install MSYS2's openssh if missing and
   write `~/.config/agent-belt/sshd/`: a host key, a config and `authorized_keys`
   (the keys Windows' sshd accepts, from ProgramData and `~/.ssh`).
2. **Loopback only:** it listens on `127.0.0.1:58022`, keys only. No new port is
   open on the network.
3. **The tray keeps it running,** without a console window and with real standard
   handles; without them sshd's per-connection child dies at once. It gets MSYS2's
   `usr\bin` on its own PATH, where `sshd-session.exe` finds its DLLs.
4. **Clients jump:** `agb attach` (and `agb new`, which creates detached then
   attaches) runs `ssh -J <windows> -p 58022 user@127.0.0.1 "tmux attach …"`. An
   ssh that fails within 8 s (exit 255: an older agb there, sshd down) falls back to
   the old path.

## Consequences

- Agents on Windows are usable from other machines: typing no longer stalls while
  they draw.
- One more process on the Windows machine, supervised by the tray; without the tray
  attaches take the old path.
- The jump costs a second ssh handshake (both over the tailnet); the old path spent
  about 2 s in PowerShell and the login bash anyway.
- Its host key is pinned under the alias `agb-<machine>-msys` in `known_hosts`.
