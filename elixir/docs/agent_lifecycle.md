# Agent Lifecycle

How Symphony runs a Claude Code agent from dispatch to completion.

## Overview

```
Orchestrator
  -> AgentRunner.run(issue)
       -> CLI.run(prompt, workspace)            # Turn 1
       -> CLI.resume(session_id, prompt, ...)   # Turn 2+
       -> ...until SYMPHONY_TASK_COMPLETE or max_turns
```

The orchestrator spawns one `AgentRunner` process per issue. The agent runner manages a loop of CLI turns, each of which is a full Claude Code subprocess.

## Turn model

Symphony has two levels of "turns":

1. **CLI turns** (`claude.max_turns` in WORKFLOW.md) — how many internal tool-use cycles Claude Code runs within a single subprocess. Default: 25.
2. **Agent turns** (`agent.max_turns` in WORKFLOW.md) — how many CLI subprocesses the agent runner will spawn in sequence. Default: 10.

So a single issue can get up to `agent.max_turns * claude.max_turns` internal tool cycles (e.g. 10 * 25 = 250).

### Turn 1 (first turn)

- `PromptBuilder` renders the WORKFLOW.md template with issue data (Liquid syntax)
- `CLI.run(prompt, workspace)` spawns `claude -p <prompt> --output-format stream-json --verbose`
- The CLI streams JSON events back via a PTY-wrapped Port

### Turns 2+ (continuation)

Between turns, the agent runner:

1. Checks if the agent emitted `SYMPHONY_TASK_COMPLETE` — if yes, stops
2. Fetches the issue state from Linear — if terminal (Done, Closed, etc.), stops
3. Fetches new `@agent` comments from Linear (see [Messaging the agent](#messaging-the-agent))
4. Builds a continuation prompt with the comments and clear completion criteria
5. `CLI.resume(session_id, prompt, workspace)` resumes the same Claude session

The continuation prompt tells the agent to:
- Check if a PR already exists
- If PR exists and CI is green, emit `SYMPHONY_TASK_COMPLETE` and stop
- If CI failed or reviews need addressing, fix and push
- If no PR, keep working

## Completion signal

The agent emits `SYMPHONY_TASK_COMPLETE` as literal text in its output when done.

Detection path:
```
Agent text output
  -> CLI.handle_line/3 parses stream-json events
  -> event_contains_completion_marker?/1 checks message content and result text
  -> cli_result.task_complete = true
  -> AgentRunner stops the turn loop
```

The WORKFLOW.md template instructs the agent to emit this marker in Phase 7 (Done) and in the continuation "All clear" case.

Without this marker, the agent runner keeps giving continuation turns as long as the Linear issue stays in an active state. This caused a "doom loop" where the agent would cycle through test -> post results -> check CI -> test again.

## Messaging the agent

You can redirect a running agent by posting a Linear comment on the issue. The comment **must** start with `@agent`:

```
@agent skip browser testing and ship the PR
```

### How it works

- `Linear.Client.fetch_issue_comments/2` queries the issue's comments via GraphQL
- Only comments starting with `@agent` are included (the prefix is stripped)
- The agent's own posts (test reports, etc.) don't have this prefix, so they're ignored
- Comments are filtered by a timestamp watermark that advances each turn, so each comment is delivered exactly once

### Timing

Comments are injected **between CLI turns**, not mid-turn. If the agent is in the middle of a 25-turn CLI session, it won't see the comment until that session ends and a continuation starts. Worst case latency is one full CLI turn (~5-60 min depending on task complexity).

## Phase tracking

The orchestrator infers the agent's current workflow phase from tool usage in the stream-json events:

| Tools used | Inferred phase |
|---|---|
| Read, Grep, Glob, WebFetch, WebSearch | Investigate |
| Edit, Write, MultiEdit | Implement |
| `mix test`, `mix check`, Playwright MCP tools | Test |
| `gh pr create`, `git push` | Ship |
| `curl` to `linear.app` | Share Evidence |

Phase is "sticky" — it only changes when a new phase is detected, never resets to nil.

## PR URL extraction

The orchestrator also extracts PR URLs from:
- Assistant text containing `github.com/.../pull/\d+`
- Tool result stdout (e.g., output of `gh pr create`)
- Result events

Once detected, the PR URL appears on the web dashboard and in completed history.

## Completed history

When an agent finishes (process exits), the orchestrator records:
- Issue identifier
- Start/end timestamps
- Final phase and PR URL
- Outcome (completed or failed)
- Turn count and token usage

If an issue is re-dispatched (continuation attempt), stale completed_history entries for that issue are removed to prevent duplicate display.

## Timeouts

| Config key | Default | What it does |
|---|---|---|
| `claude.turn_timeout_ms` | 3,600,000 (1hr) | Max wall time for a single CLI subprocess |
| `claude.stall_timeout_ms` | 600,000 (10min) | Max time without any output before killing |
| `claude.max_turns` | 25 | Internal Claude tool-use cycles per subprocess |
| `agent.max_turns` | 10 | Max CLI subprocesses per issue |

## Configuration (WORKFLOW.local.md)

```yaml
agent:
  backend: claude
  max_concurrent_agents: 2
  max_turns: 10

claude:
  command: claude
  dangerously_skip_permissions: true
  max_turns: 25
  stall_timeout_ms: 600000
  turn_timeout_ms: 3600000
```

### Running on a gf_engineering machine

On machines that use the gf_engineering workspace layout, working copies live at
`$GEARFLOW_WORKSPACE/local-dev/<repo>-slot<N>` and slot ownership is a single
atomic lease in `$GEARFLOW_WORKSPACE/local-dev/registry/` shared with interactive
Claude sessions. The harness owns those slots, so Symphony's hooks call the
harness and nothing in this fork claims, resets or releases a slot (GEA-10251).
Use the hooks in `agents/WORKFLOW.symphony.md` from gf_harness_surfaces:

* `before_run` maps `SYMPHONY_REPO` (the raw repo name, for example
  `gf_procurement` or `symphony`) to `agents/provision-slot.sh`.
* `before_remove` calls `local-dev/bin/lease release` once the issue is finished.

```yaml
tracker:
  # Assign claimed issues to a human, not the automation bot. Symphony posts with
  # the automation key, so without this a claim is assigned to the API actor.
  # User id or email; falls back to the LINEAR_CLAIM_ASSIGNEE env var, then the bot.
  claim_assignee: you@example.com
```

A lease that no hook released stays in place. `local-dev/bin/slot-status --stale`
lists it and `lease claim --reclaim` takes it.

## Key files

| File | Role |
|---|---|
| `lib/symphony_elixir/claude/agent_runner.ex` | Turn loop, comment injection, completion detection |
| `lib/symphony_elixir/claude/cli.ex` | Spawns Claude CLI, streams events, detects SYMPHONY_TASK_COMPLETE |
| `lib/symphony_elixir/claude/stream_parser.ex` | Parses stream-json, infers phase, extracts PR URLs |
| `lib/symphony_elixir/linear/client.ex` | Linear GraphQL client, comment fetching with @agent filter |
| `lib/symphony_elixir/orchestrator.ex` | Dispatches issues, tracks phase/PR/history, powers dashboard |
| `WORKFLOW.local.md` | Agent instructions template (Liquid), rendered as turn-1 prompt |
