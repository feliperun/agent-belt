# Agent stats and quotas

The agents menu shows, per session, the title, recap, time, cost and tokens, and the
plan quotas in the footer. Everything comes from the agents' own local files;
nothing is sent or authenticated. Code in `src/agent_stats.m`.

| Data | Source |
|---|---|
| live session → transcript | `~/.claude/sessions/<pid>.json` (`sessionId`, `tmux` with the pane, `startedAt`, `parkedJobId`/`jobId` for sessions parked in a background process) |
| match to the terminal | tmux pane (`%24`) or the process's `ORCA_TERMINAL_HANDLE` |
| title | last `custom-title`, otherwise the transcript's `ai-title` |
| recap | last `system/away_summary`, otherwise `last-prompt` |
| tokens and cost | `message.usage` of each `assistant`, **deduplicated by `message.id`** (one line per block, repeated usage), plus `subagents/*.jsonl`; Anthropic list price (table in the code, 2026-09-23) |
| time | the process's `startedAt` |
| Claude quota | only exists in the JSON Claude Code passes to the statusline: `~/.claude/statusline-command.sh` saves the latest one to `~/Library/Caches/agent-belt/claude-statusline.json` (`rate_limits.five_hour`/`seven_day`) |
| Codex quota | last `token_count` with `rate_limits.primary` (5 h) and `secondary` (7 d) in the rollouts under `~/.codex/sessions` |

Transcripts are read incrementally (offset per file) and only lines with relevant
markers go through the parser. The cost is the API equivalent:
on subscription plans, it is not a charge.

Codex sessions don't have per-session title/cost yet (the process →
rollout mapping hasn't been verified against a live Codex); the Codex quota does show.

## Away alert

An agent waiting on a decision for 3 min, with the Mac idle for 2 min, runs an alert
sender once per wait, with the session title as its only argument. The sender is a
program named `ford-send` on `PATH`, or whatever `AGENT_BELT_FORD_SEND` points at;
none is shipped, and without one nothing is sent.
