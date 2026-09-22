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

## Worker Slot Setup

Symphony uses a pool of pre-built workspace slots so agents start working immediately instead of
cloning and compiling from scratch each time. Each slot is a full checkout of the target repo with
compiled dependencies, a seeded database, and running backend/frontend services.

### Architecture

```
~/code/symphony-workspaces/     ← Symphony scratch workspaces (one per issue)
  GEA-1234/
    .symphony_slot              ← points to the claimed pool slot

~/Documents/Gearflow/           ← Pool slot directories (persistent clones)
  procurement-5/                ← Symphony slot (procurement repo)
  procurement-6/
  procurement-7/
  procurement-8/
  platform-5/                   ← Symphony slot (platform repo)
  platform-6/
  platform-7/
  platform-8/
```

When Symphony dispatches an agent for an issue:

1. Creates a scratch workspace under `workspace.root` (configured in `WORKFLOW.md`)
2. Runs the `before_run` hook, which calls `slot-claim.sh`
3. `slot-claim.sh` finds an unlocked slot (5-8), checks out the issue branch, runs migrations,
   starts services, and writes `.symphony_slot` with the slot path and ports
4. The agent runs in the pool slot directory (not the scratch workspace)
5. When the agent finishes, `slot-release.sh` stops services, cleans git state, and removes the lock

### Prerequisites

Each pool slot needs:

- **A clone of the target repo** in `~/Documents/Gearflow/<repo>-<N>/`
- **PostgreSQL** running on the expected port (25432 for platform, 25433 for procurement)
- **A seeded database** named `gf_<repo>_<N>_dev`
- **devenv** configured in the repo (provides Elixir, Node, and other dependencies via Nix)

### Port Assignments

Slots 5-8 are reserved for Symphony. Slots 1-4 are reserved for the separate `cc-*` worker pool
(manual Claude Code sessions managed by a supervisor agent).

| Slot | Phoenix Port | Frontend Port | Database |
|------|-------------|---------------|----------|
| platform-5 | 3009 | 5209 | gf_platform_5_dev |
| platform-6 | 3010 | 5210 | gf_platform_6_dev |
| platform-7 | 3011 | 5211 | gf_platform_7_dev |
| platform-8 | 3012 | 5212 | gf_platform_8_dev |
| procurement-5 | 3013 | 5213 | gf_procurement_5_dev |
| procurement-6 | 3014 | 5214 | gf_procurement_6_dev |
| procurement-7 | 3015 | 5215 | gf_procurement_7_dev |
| procurement-8 | 3016 | 5216 | gf_procurement_8_dev |

Platform slots use PostgreSQL on port **25432** (with PostGIS + pgvector).
Procurement slots use PostgreSQL on port **25433**.

### First-Time Slot Setup

For each slot, clone the repo and create the database:

```bash
# Example: set up procurement-5
SLOT_DIR=~/Documents/Gearflow/procurement-5
git clone git@github.com:GearFlowDev/gf_procurement.git "$SLOT_DIR"
cd "$SLOT_DIR"

# Write the .env with port assignments
cat > .env <<EOF
export PHOENIX_PORT=3013
export FRONTEND_PORT=5213
export DATABASE_NAME=gf_procurement_5_dev
export POSTGRES_PORT=25433
EOF

# Ensure .envrc exists for direnv
cat > .envrc <<'EOF'
eval "$(devenv direnvrc)"
use devenv
if [ -f .env ]; then set -a; source .env; set +a; fi
EOF
direnv allow .

# Create and seed the database
direnv exec . mix ecto.create
direnv exec . mix ecto.migrate
direnv exec . mix run priv/repo/seed.local.exs
```

Repeat for each slot, adjusting the port numbers and database name per the table above.

### How slot-claim.sh Works

The `before_run` hook in `WORKFLOW.md` calls `slot-claim.sh` with the repo type, branch name,
and scratch workspace path. The script:

1. Checks if this workspace already has a claimed slot (idempotent)
2. Releases stale locks (matching workspace/branch, self-referential, or missing workspace dir)
3. Finds the first unlocked slot (5-8)
4. Verifies PostgreSQL is running on the expected port
5. Cleans git state and checks out the issue branch (fetches from origin, rebases on main)
6. Runs `mix deps.get` and `mix ecto.migrate`
7. Writes `.env` and `.envrc` with the slot's port assignments
8. Starts backend and frontend via `devenv-start.sh`
9. Writes `.symphony_slot` to the scratch workspace with slot info

If the backend is already healthy on the expected port, it skips stopping/starting services.

### How slot-release.sh Works

Called by the `before_remove` hook when Symphony cleans up a workspace. The script:

1. Reads `.symphony_slot` from the workspace to find the slot
2. Stops backend and frontend services
3. Cleans git state (checkout main, reset to origin/main)
4. Removes the `.symphony.lock` file
5. Removes the `.symphony_slot` marker from the workspace

### Troubleshooting

**"No symphony slots available"** — All 4 slots for that repo are locked. Check for stale locks:

```bash
ls ~/Documents/Gearflow/procurement-*/.symphony.lock
cat ~/Documents/Gearflow/procurement-5/.symphony.lock
# Remove stale locks manually if needed
rm ~/Documents/Gearflow/procurement-5/.symphony.lock
```

**"Postgres not running on port X"** — Start PostgreSQL from any slot of that repo type:

```bash
cd ~/Documents/Gearflow/procurement-1
direnv exec . devenv up -d postgres
```

**Backend not starting** — Check that `.envrc` exists in the slot directory. Without it,
`direnv exec .` is a no-op and the backend starts with wrong config.

**Services on wrong port** — The `.env` file in the slot directory controls port assignments.
Verify it matches the expected ports for that slot number.

## Project Layout

- `lib/`: application code and Mix tasks
- `priv/scripts/`: shell scripts bundled into the release (slot-claim, slot-release, devenv-start, linear-upload-image)
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
