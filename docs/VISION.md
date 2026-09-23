# Agent Belt — Product Vision

## Why now

Working with several coding agents at once (Claude Code, Codex) turns the developer
into a dispatcher: dictating instructions, noticing which agent is waiting for a
decision, jumping to it, and starting new ones on other machines. Doing that with
the keyboard and the mouse means constant context switches.

## The problem

Agents wait silently. A permission prompt sits unanswered in a tab nobody is looking
at; a finished task goes unnoticed; starting a session on the Windows box means SSH,
tmux and a worktree by hand. Typing long instructions is slower than saying them.

## The bet

A cheap 6-key macropad with a knob, plus the Mac's own keyboard, is enough to run a
fleet of agents: hold a key to dictate, one key jumps to the agent that needs you,
the key lights tell you when to look, and a sentence creates a new agent anywhere on
the tailnet. Everything stays local except the transcription call.

## Principles

- Local first: agent state comes from the agents' own files and terminals; no cloud
  service, no telemetry.
- Never steal focus or input: the overlay, HUD and menu never activate, and
  dictation waits for them to disappear before typing.
- Configuration lives in code (`src/config.zig`); the installer regenerates it.

## Next milestone

Daily use without friction on one Mac: dictation, agent switching, voice-created
agents and updates that keep macOS privacy grants.

## Non-goals (for now)

- Windows and Linux daemons (the `work` engine already runs there).
- Keypad key remapping through the vendor protocol.
- A settings UI.
