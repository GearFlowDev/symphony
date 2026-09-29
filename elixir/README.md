# Symphony Elixir

This directory contains the current Elixir/OTP implementation of Symphony, based on
[`SPEC.md`](../SPEC.md) at the repository root.

> [!WARNING]
> Symphony Elixir is prototype software intended for evaluation only and is presented as-is.
> We recommend implementing your own hardened version based on `SPEC.md`.

## Screenshot

![Symphony Elixir screenshot](../.github/media/elixir-screenshot.png)

## How it works

1. Polls Linear for candidate work
2. Creates an isolated workspace per issue
3. Launches Codex in [App Server mode](https://developers.openai.com/codex/app-server/) inside the
   workspace
4. Sends a workflow prompt to Codex
5. Keeps Codex working on the issue until the work is done

During app-server sessions, Symphony also serves a client-side `linear_graphql` tool so that repo
skills can make raw Linear GraphQL calls.

If a claimed issue moves to a terminal state (`Done`, `Closed`, `Cancelled`, or `Duplicate`),
Symphony stops the active agent for that issue and cleans up matching workspaces.

## How to use it

1. Make sure your codebase is set up to work well with agents: see
   [Harness engineering](https://openai.com/index/harness-engineering/).
2. Get a new personal token in Linear via Settings → Security & access → Personal API keys, and
   set it as the `LINEAR_API_KEY` environment variable.
3. Copy this directory's `WORKFLOW.md` to your repo.
4. Optionally copy the `commit`, `push`, `pull`, `land`, and `linear` skills to your repo.
   - The `linear` skill expects Symphony's `linear_graphql` app-server tool for raw Linear GraphQL
     operations such as comment editing or upload flows.
5. Customize the copied `WORKFLOW.md` file for your project.
   - To get your project's slug, right-click the project and copy its URL. The slug is part of the
     URL.
   - When creating a workflow based on this repo, note that it depends on non-standard Linear
     issue statuses: "Rework", "Human Review", and "Merging". You can customize them in
     Team Settings → Workflow in Linear.
6. Follow the instructions below to install the required runtime dependencies and start the service.

## Prerequisites

We recommend using [mise](https://mise.jdx.dev/) to manage Elixir/Erlang versions.

```bash
mise install
mise exec -- elixir --version
```

## Run

### Development

```bash
cd symphony/elixir
mix setup        # fetch deps
mix phx.server   # start with dashboard + status TUI
```

The server reads `WORKFLOW.md` from the current directory, starts polling Linear, and serves the
dashboard at the port configured in the `server.port` frontmatter field (default: 4040).

The status TUI draws only when stdout is a terminal. Redirect it, pipe it, or hand it to a
container's log stream, and Symphony writes one log line per state change instead — see
[docs/logging.md](docs/logging.md). (A container with a TTY attached still gets the board; the
device is what decides, not the word "container".) `SYMPHONY_STATUS_BOARD=off` forces the log
on a terminal too; `=on` forces the board anywhere. The web dashboard is the same either way.

### Production (release)

```bash
MIX_ENV=prod mix release symphony --overwrite
_build/prod/rel/symphony/bin/symphony start
```

The release bundles the BEAM, dependencies, and native libraries (SQLite NIF) into a
self-contained directory. Run it from the `elixir/` directory so it finds `WORKFLOW.md`.

Other release commands:

```bash
_build/prod/rel/symphony/bin/symphony stop     # graceful shutdown
_build/prod/rel/symphony/bin/symphony remote   # attach a remote IEx shell
_build/prod/rel/symphony/bin/symphony rpc '...' # evaluate an expression
```

### From scratch (upstream)

```bash
git clone https://github.com/openai/symphony
cd symphony/elixir
mise trust
mise install
mise exec -- mix setup
mise exec -- MIX_ENV=prod mix release symphony
mise exec -- _build/prod/rel/symphony/bin/symphony start
```

## Configuration

Pass a custom workflow file path to `./bin/symphony` when starting the service:

```bash
./bin/symphony /path/to/custom/WORKFLOW.md
```

If no path is passed, Symphony defaults to `./WORKFLOW.md`.

Optional flags:

- `--logs-root` tells Symphony to write logs under a different directory (default: `./log`)
- `--port` also starts the Phoenix observability service (default: disabled)

The `WORKFLOW.md` file uses YAML front matter for configuration, plus a Markdown body used as the
Codex session prompt.

Minimal example:

```md
---
tracker:
  kind: linear
  filter:
    labels:
      include:
        - symphony-agent
workspace:
  root: ~/code/workspaces
hooks:
  after_create: |
    git clone git@github.com:your-org/your-repo.git .
agent:
  max_concurrent_agents: 10
  max_turns: 20
codex:
  command: codex app-server
---

You are working on a Linear issue {{ issue.identifier }}.

Title: {{ issue.title }} Body: {{ issue.description }}
```

Notes:

- If a value is missing, defaults are used.
- Safer Codex defaults are used when policy fields are omitted:
  - `codex.approval_policy` defaults to `{"reject":{"sandbox_approval":true,"rules":true,"mcp_elicitations":true}}`
  - `codex.thread_sandbox` defaults to `workspace-write`
  - `codex.turn_sandbox_policy` defaults to a `workspaceWrite` policy rooted at the current issue workspace
- Supported `codex.approval_policy` values depend on the targeted Codex app-server version. In the current local Codex schema, string values include `untrusted`, `on-failure`, `on-request`, and `never`, and object-form `reject` is also supported.
- Supported `codex.thread_sandbox` values: `read-only`, `workspace-write`, `danger-full-access`.
- Supported `codex.turn_sandbox_policy.type` values: `dangerFullAccess`, `readOnly`,
  `externalSandbox`, `workspaceWrite`.
- `agent.max_turns` caps how many back-to-back Codex turns Symphony will run in a single agent
  invocation when a turn completes normally but the issue is still in an active state. Default: `20`.
- If the Markdown body is blank, Symphony uses a default prompt template that includes the issue
  identifier, title, and body.
- Use `hooks.after_create` to bootstrap a fresh workspace. For a Git-backed repo, you can run
  `git clone ... .` there, along with any other setup commands you need.
- If a hook needs `mise exec` inside a freshly cloned workspace, trust the repo config and fetch
  the project dependencies in `hooks.after_create` before invoking `mise` later from other hooks.
- `tracker.api_key` reads from `LINEAR_API_KEY` when unset or when value is `$LINEAR_API_KEY`.
- For path values, `~` is expanded to the home directory.
- For env-backed path values, use `$VAR`. `workspace.root` resolves `$VAR` before path handling,
  while `codex.command` stays a shell command string and any `$VAR` expansion there happens in the
  launched shell.

```yaml
tracker:
  api_key: $LINEAR_API_KEY
workspace:
  root: $SYMPHONY_WORKSPACE_ROOT
hooks:
  after_create: |
    git clone --depth 1 "$SOURCE_REPO_URL" .
codex:
  command: "$CODEX_BIN app-server --model gpt-5.3-codex"
```

- If `WORKFLOW.md` is missing or has invalid YAML, startup and scheduling are halted until fixed.
- `server.port` or CLI `--port` enables the optional Phoenix LiveView dashboard and JSON API at
  `/`, `/api/v1/state`, `/api/v1/<issue_identifier>`, and `/api/v1/refresh`.

## Web dashboard

The observability UI now runs on a minimal Phoenix stack:

- LiveView for the dashboard at `/`
- JSON API for operational debugging under `/api/v1/*`
- Bandit as the HTTP server
- Phoenix dependency static assets for the LiveView client bootstrap

## Worker Slots

Symphony does not own slots. The machine's harness does: its `before_run` hook provisions or
reuses a slot and writes `.symphony_slot` into the scratch workspace, and its `before_remove`
hook releases the lease. On a gf_engineering machine those hooks call
`local-dev/gf_harness_surfaces/agents/provision-slot.sh` and `local-dev/bin/lease release`;
see `agents/WORKFLOW.symphony.md` in gf_harness_surfaces.

When Symphony dispatches an agent for an issue:

1. It creates a scratch workspace under `workspace.root`.
2. It runs `before_run` with `SYMPHONY_REPO` set to the raw repository name: the repo of the
   issue's GearFlowDev PR, else `gf_platform` for a `2.0` label or `gf_procurement` for a
   `3.0` label, else empty. The hook maps that name to a slot.
3. The agent runs in the slot that `.symphony_slot` names.
4. When a run ends, Symphony runs `before_remove` once. The hook decides whether to release.

Symphony never resets a slot tree and never deletes a lease file. A lease that nobody
released is the harness's job: `local-dev/bin/slot-status --stale` lists it and
`lease claim --reclaim` takes it (GEA-10251).

## Project Layout

- `lib/`: application code and Mix tasks
- `priv/scripts/`: shell scripts bundled into the release (linear-upload-image, linear-embed-images, change-census)
- `test/`: ExUnit coverage for runtime behavior
- `WORKFLOW.md`: in-repo workflow contract used by local runs
- `workflow/stages/`: stage-specific prompt templates (e.g., human-review)
- `../.codex/`: repository-local Codex skills and setup helpers

## Testing

```bash
make all
```

## FAQ

### Why Elixir?

Elixir is built on Erlang/BEAM/OTP, which is great for supervising long-running processes. It has an
active ecosystem of tools and libraries. It also supports hot code reloading without stopping
actively running subagents, which is very useful during development.

### What's the easiest way to set this up for my own codebase?

Launch `codex` in your repo, give it the URL to the Symphony repo, and ask it to set things up for
you.

## License

This project is licensed under the [Apache License 2.0](../LICENSE).
