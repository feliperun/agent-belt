---
type: ADR
id: "0009"
title: "New agents open in Orca or cmux, as configured"
status: active
date: 2026-10-01
---

## Context

[ADR 0005](0005-new-agents-in-their-orca-project.md) made the Mac's agent switcher
and the create-agent panel work with Orca only: Orca's terminals were the ring,
`orca terminal switch` focused one, and a new agent opened as a workspace in its
repository's Orca project. cmux is the same kind of app (workspaces holding
terminals, a CLI over a socket), and an agent running in cmux was invisible.

What cmux offers, checked against its CLI:

- A terminal is a *surface* inside a *workspace*; both have UUIDs. Every process
  it starts carries `CMUX_SURFACE_ID` and `CMUX_WORKSPACE_ID`, the way Orca's
  carry `ORCA_TERMINAL_HANDLE`.
- `cmux tree --all --json` lists every surface with its title and workspace.
  Nothing in it says an agent runs there; `cmux sessions list --json` does: the
  records cmux's agent hooks keep (agent, pid, surface id, lifecycle `running`,
  `idle` or `needsInput`), read from `~/.cmuxterm` without the socket.
- `cmux workspace create --cwd … --name … --command … --focus true` opens a
  workspace whose terminal runs the command typed into its shell.
- cmux answers only processes it started (`cmuxOnly`, its default), so the
  launchd daemon is refused ("only processes started inside cmux can connect")
  until the socket mode allows other local processes. `automation` does:
  checked with a launchd job outside cmux, which listed the tree, focused a
  surface and created a workspace.

## Decision

**The switcher and the panel work with both apps; each target remembers which one
hosts it.**

1. **Ring:** `MKOrcaTargets` and `MKCmuxTargets` (`src/agent_switcher.m`) list
   each app's terminals running an agent. A tmux client is matched to its terminal
   by `MKHostedHandle`, which reads `ORCA_TERMINAL_HANDLE` or `CMUX_SURFACE_ID`.
   A cmux surface counts as an agent when a tmux session in it runs one, or a hook
   record of a live process names it.
2. **State:** a cmux record's lifecycle is the agent's status (`running` is busy,
   `needsInput` is waiting), so no screen is read for it. Claude Code's own record
   still wins when it has one.
3. **Focus:** a cmux surface is selected by workspace, then focused in it; its
   workspace is looked up at that moment, since a surface can be moved.
4. **New agent:** `agb _tab-open <orca|cmux> <agb new arguments>`
   (`src/sessions/tabs.zig`) replaces `_orca-open`. The placement rules of
   ADR 0005 stay (an agent here gets a workspace in its worktree, one on another
   machine gets one in this machine's clone, no repo keeps the caller's terminal);
   `orca.zig` registers the repo and creates the tab, `cmux.zig` creates the
   workspace, which needs no registration. The app is the `terminal` setting of
   `config.json` (`"cmux"` by default, or `"orca"`), handed to the switcher at
   startup (`mk_agents_set_terminal`); when it is not running, the agent opens
   in a Terminal window as before.

## Options considered

- **Replace Orca with cmux.** Less code, but it drops a working integration.
- **A common "terminal host" interface in the switcher.** Two apps do not pay for
  it; the per-app functions share one shape and a bundle id on the target.

## Consequences

- cmux needs **`automation.socketControlMode: "automation"`** in
  `~/.config/cmux/cmux.json` (or the same mode in Settings > Automation), which
  lets any local process of the user drive cmux. Without it the daemon logs that
  cmux refuses it and lists no cmux agent. An `agb` run from inside a cmux
  terminal is not affected.
- Agents with no hook record and no tmux session (a harness cmux has no hook for)
  are not seen in cmux. Orca names them itself.
- ADR 0008's typed command stays Orca's: cmux types `--command` into the shell it
  starts, so there is no adoption step to lose it in.
