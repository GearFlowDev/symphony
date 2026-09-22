# Logging Best Practices

This guide defines logging conventions for Symphony so Codex can diagnose failures quickly.

## Goals

- Make logs searchable by issue and session.
- Capture enough execution context to identify root cause without reruns.
- Keep messages stable so dashboards/alerts are reliable.

## Required Context Fields

When logging issue-related work, include both identifiers:

- `issue_id`: Linear internal UUID (stable foreign key).
- `issue_identifier`: human ticket key (for example `MT-620`).

When logging Codex execution lifecycle events, include:

- `session_id`: combined Codex thread/turn identifier.

## Message Design

- Use explicit `key=value` pairs in message text for high-signal fields.
- Prefer deterministic wording for recurring lifecycle events.
- Include the action outcome (`completed`, `failed`, `retrying`) and the reason/error when available.
- Avoid logging large payloads unless required for debugging.

## Where The Lines Go

Stdout belongs to whichever surface can use it.

- **A terminal** gets the status board. It homes the cursor and clears the screen on every
  refresh, so a log line written between two frames is wiped before anyone reads it: the
  console handler is removed and the rotating disk log is the only sink.
- **Anything else** — a pipe, a file, a container's log stream — gets the log. There is no
  board at all, no escape sequence is written, and the lifecycle lines below are the status:
  they stay on stdout at `:info`, one line each, without colour.

`SymphonyElixir.StatusOutput` decides, asking `:io.columns/0` about the device the board
would be written to. `SYMPHONY_STATUS_BOARD=off` forces the log, `=on` forces the board.
The web dashboard on `server.port` is unaffected by either.

This is why a lifecycle event must be one line. On a container's log stream these lines are
all an operator has, and the window they live in is bounded.

## Scope Guidance

- `AgentRunner`: log start/completion/failure with issue context, plus `session_id` when known.
- `Orchestrator`: log dispatch, retry, phase changes, terminal/non-active transitions, and worker exits with issue context. Include `session_id` whenever running-entry data has it. Log each poll's result (`candidates`, `dispatched`) when it differs from the previous poll's, and not otherwise — a line every interval refills a bounded log window on its own.
- `Codex.AppServer`: log session start/completion/error with issue context and `session_id`.

## Checklist For New Logs

- Is this event tied to a Linear issue? Include `issue_id` and `issue_identifier`.
- Is this event tied to a Codex session? Include `session_id`.
- Is the failure reason present and concise?
- Is the message format consistent with existing lifecycle logs?
