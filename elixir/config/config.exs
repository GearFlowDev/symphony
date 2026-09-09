import Config

config :phoenix, :json_library, Jason

# The test suite resets the runs table, so :test must never share the dev/prod DB.
config :symphony_elixir, SymphonyElixir.Repo,
  database: Path.expand(if(config_env() == :test, do: "~/.symphony/symphony_test.db", else: "~/.symphony/symphony.db")),
  pool_size: 1,
  journal_mode: :wal

config :symphony_elixir,
  ecto_repos: [SymphonyElixir.Repo]

# In test, bind an ephemeral port so the suite never collides with a running
# dev server (which holds the workflow-configured port).
if config_env() == :test, do: config(:symphony_elixir, server_port_override: 0)

# `mix test` boots the application on the same host as the live orchestrator.
# A test BEAM owns no runs, so its startup and per-poll reapers would see every
# live worker's tmux session and slot lease as orphaned and kill them. Only the
# real orchestrator reaps.
if config_env() == :test, do: config(:symphony_elixir, reap_orphans: false)

config :symphony_elixir, SymphonyElixirWeb.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  url: [host: "localhost"],
  render_errors: [
    formats: [html: SymphonyElixirWeb.ErrorHTML, json: SymphonyElixirWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: SymphonyElixir.PubSub,
  live_view: [signing_salt: "symphony-live-view"],
  secret_key_base: String.duplicate("s", 64),
  check_origin: false,
  server: false
