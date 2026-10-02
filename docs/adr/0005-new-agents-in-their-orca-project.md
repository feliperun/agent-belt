---
type: ADR
id: "0005"
title: "New agents open in their repository's Orca project"
status: superseded
superseded_by: "0009"
date: 2026-09-27
---

## Context

With Orca open, the create-agent panel ran `agb new` in a tab of the home folder
(`orca terminal create --worktree path:~`). Every agent landed in the same place,
whatever repository it worked in, and Orca's projects and workspaces, its way of
organizing work, did not show them.

Orca keys a project by the repository's git remote (`github:owner/repo`); a repo is
a local folder of that project, and each git worktree of a registered repo is a
workspace, the ones Orca did not create included: `--worktree path:<dir>` resolves
agb's worktrees. Its CLI can register a folder (`orca repo add`) but not remove one;
that takes the UI.

## Decision

`agb _orca-open <agb new arguments>` (`src/sessions/orca.zig`) places a new agent,
and the Mac panel calls it whenever Orca is running:

1. **Here, with a repo:** agb creates the worktree and the tmux session without
   attaching, then opens a tab in that worktree running `agb attach`: each agent is
   a new workspace in its repository's project.
2. **Another machine:** the tab runs `agb new --host …` in the project of this
   machine's clone of the same repository (matched by name).
3. **A repository Orca does not know is registered** (`orca repo add`), which makes
   it a project.
4. **No repo, or no local clone:** exit 2, and the panel opens its terminal as before
   (`agb new` attaches to the session if the first attempt created it).

The tab is created without `--focus` and brought forward with `terminal switch`:
`--focus` times out on a workspace Orca keeps hidden (a repo that hides worktrees it
did not create). Its command line sets the terminal title first, since the shell
titles the tab with the command it runs.

## Consequences

- Agents show up where their code is, one workspace each; research agents and
  repositories without a clone here keep the old behavior.
- Registering is one-way from agb: a repo it added can only be removed in Orca's UI.
- The agent tab of another machine sits in the local clone's main workspace, since
  the remote worktree is not a folder Orca can see.
