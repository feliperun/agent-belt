---
type: ADR
id: "0008"
title: "The command that opens a tab is typed into the terminal, not passed to create"
status: active
date: 2026-09-29
---

## Context

Tapping an agent that has no terminal open in the menu bar opened a new Orca tab
on a bare shell prompt: the tab appeared and the session never attached, because
`agb attach` was never called. The daemon logged no fallback (`Orca did not open
the tab`), so `terminal create` had returned a handle and Orca had created the
tab.

The command was passed as `orca terminal create --command <line>`. Orca types a
creation command when its UI adopts the tab; its own help says it "creates a
visible terminal tab without switching focus when possible; **falls back to a
background handle if the UI cannot adopt it**". A tab Orca keeps in the
background therefore opens without the command, and the failure is silent: the
tab exists, so nothing reports an error.

## Decision

**A tab is created without `--command`, and the line is typed into it afterwards
with `orca terminal send --terminal <handle> --text <line> --enter`.** One owner
for the line, and the send reports whether it was accepted.

`src/agent_switcher.m` (`MKTabCreate`, `MKTabRun`) does this for the menu and the
panel. A line sent before the shell is ready is held by the terminal until it is
read, so no wait is needed; `terminal wait --for tui-idle` does not apply, since a
shell at a prompt is not an idle TUI.

## Options considered

- **Keep `--command` and retry when the tab is empty.** Needs a read-back to tell
  an empty tab from a slow one, and a retry that may type the line twice.
- **Wait for Orca to adopt the tab before creating.** No such signal exists; the
  CLI returns a handle either way.

## Consequences

- The tab opens even when Orca holds it in the background, and the session
  attaches in every case.
- Two CLI calls instead of one, both observable in the daemon log.
- `src/sessions/orca.zig` still passes `--command`: it creates the tab in a
  worktree Orca itself registered, which its UI adopts. If that path ever opens an
  empty tab, the fix is the same.
