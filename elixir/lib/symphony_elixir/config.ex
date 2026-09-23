defmodule SymphonyElixir.Config do
  @moduledoc """
  Runtime configuration loaded from `WORKFLOW.md`.
  """

  alias NimbleOptions
  alias SymphonyElixir.Workflow

  @default_active_states ["Todo", "In Progress"]
  @default_terminal_states ["Closed", "Cancelled", "Canceled", "Duplicate", "Done"]
  @default_linear_endpoint "https://api.linear.app/graphql"
  @default_prompt_template """
  You are working on a Linear issue.

  Identifier: {{ issue.identifier }}
  Title: {{ issue.title }}

  Body:
  {% if issue.description %}
  {{ issue.description }}
  {% else %}
  No description provided.
  {% endif %}
  """
  @default_poll_interval_ms 30_000
  @default_workspace_root Path.join(System.tmp_dir!(), "symphony_workspaces")
  @default_hook_timeout_ms 60_000
  @default_max_concurrent_agents 10
  @default_agent_max_turns 20
  @default_max_retry_backoff_ms 300_000
  @default_max_failure_retries 3
  # Churn guards (2026-07-15): a converging issue needs well under a dozen
  # dispatches a day; GEA-4621 burned 42 in one day without progress.
  @default_max_dispatches_per_issue_per_day 12
  @default_plan_cycle_repeat_limit 3
  @default_agent_backend "codex"
  @default_codex_command "codex app-server"
  # Claude Code defaults
  @default_claude_command "claude"
  @default_claude_turn_timeout_ms 3_600_000
  @default_claude_stall_timeout_ms 300_000
  @default_claude_output_format "stream-json"
  @default_claude_max_turns 50
  @default_claude_permission_mode "default"
  @default_claude_dangerously_skip_permissions false
  @default_claude_tmux_session_prefix "symphony"
  @default_claude_tmux_width 200
  @default_claude_tmux_height 50
  @default_claude_tmux_startup_delay_ms 2_000
  @default_claude_tmux_paste_settle_ms 1_500
  @default_claude_tmux_ready_poll_interval_ms 500
  @default_claude_tmux_ready_timeout_ms 30_000
  @default_claude_tmux_jsonl_base_path "~/.claude/projects"
  @default_claude_tmux_jsonl_poll_interval_ms 250
  @default_codex_turn_timeout_ms 3_600_000
  @default_codex_read_timeout_ms 5_000
  @default_codex_stall_timeout_ms 300_000
  @default_codex_approval_policy %{
    "reject" => %{
      "sandbox_approval" => true,
      "rules" => true,
      "mcp_elicitations" => true
    }
  }
  @default_codex_thread_sandbox "workspace-write"
  @default_observability_enabled true
  @default_observability_refresh_ms 1_000
  @default_observability_render_interval_ms 16
  @default_server_host "127.0.0.1"
  @default_escalation_eval_score_threshold 60
  @workflow_options_schema NimbleOptions.new!(
                             tracker: [
                               type: :map,
                               default: %{},
                               keys: [
                                 kind: [type: {:or, [:string, nil]}, default: nil],
                                 endpoint: [type: :string, default: @default_linear_endpoint],
                                 api_key: [type: {:or, [:string, nil]}, default: nil],
                                 # project_slug is deprecated — kept in schema for backward compat but unused
                                 project_slug: [type: {:or, [:string, nil]}, default: nil],
                                 filter: [type: {:or, [{:map, :any, :any}, nil]}, default: nil],
                                 # `assignee` is a ROUTING filter: when set, only issues
                                 # already assigned to this user are picked up. Leave nil
                                 # to route by label alone (pick up unassigned issues too).
                                 assignee: [type: {:or, [:string, nil]}, default: nil],
                                 # `claim_assignee` is who a claimed issue gets ASSIGNED to
                                 # (user id or email). Independent of routing — set this to a
                                 # human without restricting which issues are picked up.
                                 claim_assignee: [type: {:or, [:string, nil]}, default: nil],
                                 active_states: [
                                   type: {:list, :string},
                                   default: @default_active_states
                                 ],
                                 terminal_states: [
                                   type: {:list, :string},
                                   default: @default_terminal_states
                                 ]
                               ]
                             ],
                             polling: [
                               type: :map,
                               default: %{},
                               keys: [
                                 interval_ms: [type: :integer, default: @default_poll_interval_ms],
                                 active_hours: [
                                   type: :map,
                                   default: %{},
                                   keys: [
                                     start: [type: :integer, default: 0],
                                     end: [type: :integer, default: 24],
                                     timezone: [type: :string, default: "UTC"]
                                   ]
                                 ]
                               ]
                             ],
                             workspace: [
                               type: :map,
                               default: %{},
                               keys: [
                                 root: [type: {:or, [:string, nil]}, default: @default_workspace_root]
                               ]
                             ],
                             agent: [
                               type: :map,
                               default: %{},
                               keys: [
                                 backend: [
                                   type: :string,
                                   default: @default_agent_backend
                                 ],
                                 max_concurrent_agents: [
                                   type: :integer,
                                   default: @default_max_concurrent_agents
                                 ],
                                 max_turns: [
                                   type: :pos_integer,
                                   default: @default_agent_max_turns
                                 ],
                                 max_retry_backoff_ms: [
                                   type: :pos_integer,
                                   default: @default_max_retry_backoff_ms
                                 ],
                                 max_failure_retries: [
                                   type: :pos_integer,
                                   default: @default_max_failure_retries
                                 ],
                                 max_dispatches_per_issue_per_day: [
                                   type: :pos_integer,
                                   default: @default_max_dispatches_per_issue_per_day
                                 ],
                                 plan_cycle_repeat_limit: [
                                   type: :pos_integer,
                                   default: @default_plan_cycle_repeat_limit
                                 ],
                                 max_concurrent_agents_by_state: [
                                   type: {:map, :string, :pos_integer},
                                   default: %{}
                                 ]
                               ]
                             ],
                             suitability: [
                               type: :map,
                               default: %{},
                               keys: [
                                 skip_labels: [
                                   type: {:list, :string},
                                   default: []
                                 ],
                                 require_description: [
                                   type: :boolean,
                                   default: false
                                 ],
                                 min_priority: [
                                   type: {:or, [:pos_integer, nil]},
                                   default: nil
                                 ]
                               ]
                             ],
                             codex: [
                               type: :map,
                               default: %{},
                               keys: [
                                 command: [type: :string, default: @default_codex_command],
                                 turn_timeout_ms: [
                                   type: :integer,
                                   default: @default_codex_turn_timeout_ms
                                 ],
                                 read_timeout_ms: [
                                   type: :integer,
                                   default: @default_codex_read_timeout_ms
                                 ],
                                 stall_timeout_ms: [
                                   type: :integer,
                                   default: @default_codex_stall_timeout_ms
                                 ]
                               ]
                             ],
                             claude: [
                               type: :map,
                               default: %{},
                               keys: [
                                 command: [type: :string, default: @default_claude_command],
                                 model: [type: {:or, [:string, nil]}, default: nil],
                                 # Per-stage model overrides; fall back to `model` when nil.
                                 plan_model: [type: {:or, [:string, nil]}, default: nil],
                                 test_model: [type: {:or, [:string, nil]}, default: nil],
                                 grade_model: [type: {:or, [:string, nil]}, default: nil],
                                 fix_ci_model: [type: {:or, [:string, nil]}, default: nil],
                                 turn_timeout_ms: [
                                   type: :integer,
                                   default: @default_claude_turn_timeout_ms
                                 ],
                                 stall_timeout_ms: [
                                   type: :integer,
                                   default: @default_claude_stall_timeout_ms
                                 ],
                                 output_format: [
                                   type: :string,
                                   default: @default_claude_output_format
                                 ],
                                 max_turns: [
                                   type: :pos_integer,
                                   default: @default_claude_max_turns
                                 ],
                                 permission_mode: [
                                   type: :string,
                                   default: @default_claude_permission_mode
                                 ],
                                 dangerously_skip_permissions: [
                                   type: :boolean,
                                   default: @default_claude_dangerously_skip_permissions
                                 ],
                                 allowed_tools: [
                                   type: {:list, :string},
                                   default: []
                                 ],
                                 tmux_session_prefix: [
                                   type: :string,
                                   default: @default_claude_tmux_session_prefix
                                 ],
                                 tmux_width: [
                                   type: :pos_integer,
                                   default: @default_claude_tmux_width
                                 ],
                                 tmux_height: [
                                   type: :pos_integer,
                                   default: @default_claude_tmux_height
                                 ],
                                 tmux_startup_delay_ms: [
                                   type: :non_neg_integer,
                                   default: @default_claude_tmux_startup_delay_ms
                                 ],
                                 tmux_paste_settle_ms: [
                                   type: :non_neg_integer,
                                   default: @default_claude_tmux_paste_settle_ms
                                 ],
                                 tmux_ready_poll_interval_ms: [
                                   type: :pos_integer,
                                   default: @default_claude_tmux_ready_poll_interval_ms
                                 ],
                                 tmux_ready_timeout_ms: [
                                   type: :pos_integer,
                                   default: @default_claude_tmux_ready_timeout_ms
                                 ],
                                 tmux_jsonl_base_path: [
                                   type: :string,
                                   default: @default_claude_tmux_jsonl_base_path
                                 ],
                                 tmux_jsonl_poll_interval_ms: [
                                   type: :pos_integer,
                                   default: @default_claude_tmux_jsonl_poll_interval_ms
                                 ]
                               ]
                             ],
                             hooks: [
                               type: :map,
                               default: %{},
                               keys: [
                                 after_create: [type: {:or, [:string, nil]}, default: nil],
                                 before_run: [type: {:or, [:string, nil]}, default: nil],
                                 after_run: [type: {:or, [:string, nil]}, default: nil],
                                 before_remove: [type: {:or, [:string, nil]}, default: nil],
                                 timeout_ms: [type: :pos_integer, default: @default_hook_timeout_ms]
                               ]
                             ],
                             observability: [
                               type: :map,
                               default: %{},
                               keys: [
                                 dashboard_enabled: [
                                   type: :boolean,
                                   default: @default_observability_enabled
                                 ],
                                 refresh_ms: [
                                   type: :integer,
                                   default: @default_observability_refresh_ms
                                 ],
                                 render_interval_ms: [
                                   type: :integer,
                                   default: @default_observability_render_interval_ms
                                 ]
                               ]
                             ],
                             server: [
                               type: :map,
                               default: %{},
                               keys: [
                                 port: [type: {:or, [:non_neg_integer, nil]}, default: nil],
                                 host: [type: :string, default: @default_server_host]
                               ]
                             ],
                             escalation: [
                               type: :map,
                               default: %{},
                               keys: [
                                 eval_score_threshold: [
                                   type: :integer,
                                   default: @default_escalation_eval_score_threshold
                                 ],
                                 webhook_url: [type: {:or, [:string, nil]}, default: nil],
                                 needs_human_state: [type: {:or, [:string, nil]}, default: nil]
                               ]
                             ]
                           )

  @type workflow_payload :: Workflow.loaded_workflow()
  @type tracker_kind :: String.t() | nil
  @type codex_runtime_settings :: %{
          approval_policy: String.t() | map(),
          thread_sandbox: String.t(),
          turn_sandbox_policy: map()
        }
  @type workspace_hooks :: %{
          after_create: String.t() | nil,
          before_run: String.t() | nil,
          after_run: String.t() | nil,
          before_remove: String.t() | nil,
          timeout_ms: pos_integer()
        }

  @spec current_workflow() :: {:ok, workflow_payload()} | {:error, term()}
  def current_workflow do
    Workflow.current()
  end

  @spec tracker_kind() :: tracker_kind()
  def tracker_kind do
    get_in(validated_workflow_options(), [:tracker, :kind])
  end

  @spec linear_endpoint() :: String.t()
  def linear_endpoint do
    get_in(validated_workflow_options(), [:tracker, :endpoint])
  end

  @spec linear_api_token() :: String.t() | nil
  def linear_api_token do
    validated_workflow_options()
    |> get_in([:tracker, :api_key])
    |> resolve_env_value(System.get_env("LINEAR_API_KEY"))
    |> normalize_secret_value()
  end

  @doc """
  Returns the composable filter config for Linear issue targeting.
  """
  @spec linear_filter() :: map()
  def linear_filter do
    opts = validated_workflow_options()
    get_in(opts, [:tracker, :filter]) || %{}
  end

  @doc """
  The labels an issue must carry for this orchestrator to run it.

  Read from `tracker.filter.labels.include` — the same list the candidate query
  filters on — so the dispatch gate and the live gate cannot disagree.
  """
  @spec required_issue_labels() :: [String.t()]
  def required_issue_labels do
    linear_filter()
    |> SymphonyElixir.Linear.FilterBuilder.include_labels()
    |> Enum.map(&(&1 |> String.trim() |> String.downcase()))
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  @spec linear_assignee() :: String.t() | nil
  def linear_assignee do
    validated_workflow_options()
    |> get_in([:tracker, :assignee])
    |> resolve_env_value(System.get_env("LINEAR_ASSIGNEE"))
    |> normalize_secret_value()
  end

  # Who a claimed issue gets assigned to. Distinct from `linear_assignee/0`,
  # which is the routing filter — keeping them separate lets us assign claimed
  # issues to a human without restricting which issues Symphony picks up.
  @spec linear_claim_assignee() :: String.t() | nil
  def linear_claim_assignee do
    validated_workflow_options()
    |> get_in([:tracker, :claim_assignee])
    |> resolve_env_value(System.get_env("LINEAR_CLAIM_ASSIGNEE"))
    |> normalize_secret_value()
  end

  @spec linear_active_states() :: [String.t()]
  def linear_active_states do
    get_in(validated_workflow_options(), [:tracker, :active_states])
  end

  @spec linear_terminal_states() :: [String.t()]
  def linear_terminal_states do
    get_in(validated_workflow_options(), [:tracker, :terminal_states])
  end

  @spec poll_interval_ms() :: pos_integer()
  def poll_interval_ms do
    get_in(validated_workflow_options(), [:polling, :interval_ms])
  end

  @spec polling_active_hours() :: %{start: integer(), end: integer(), timezone: String.t()}
  def polling_active_hours do
    get_in(validated_workflow_options(), [:polling, :active_hours])
  end

  @doc """
  Returns true if the current time falls within the configured active hours.
  When start=0 and end=24 (defaults), always returns true.
  """
  @spec within_active_hours?() :: boolean()
  def within_active_hours? do
    %{start: start_hour, end: end_hour, timezone: timezone} = polling_active_hours()

    if start_hour == 0 and end_hour == 24 do
      true
    else
      case current_hour_in_timezone(timezone) do
        {:ok, hour} -> hour >= start_hour and hour < end_hour
        :error -> true
      end
    end
  end

  defp current_hour_in_timezone(timezone) do
    case System.cmd("date", ["+%H"], env: [{"TZ", timezone}], stderr_to_stdout: true) do
      {hour_str, 0} ->
        {:ok, hour_str |> String.trim() |> String.to_integer()}

      _ ->
        :error
    end
  end

  @doc """
  The directory per-issue workspaces are created under.

  A RELATIVE `workspace.root` anchors on the directory holding `WORKFLOW.md`,
  not on the orchestrator's current working directory. `Path.expand/1` against
  cwd made the root move whenever the process was started from somewhere else —
  the orchestrator then created workspaces in one tree and looked for them in
  another (upstream cbd2158).
  """
  @spec workspace_root() :: Path.t()
  def workspace_root do
    validated_workflow_options()
    |> get_in([:workspace, :root])
    |> resolve_workspace_root()
  end

  defp resolve_workspace_root(value) when is_binary(value) do
    case normalize_path_token(value) do
      :missing -> @default_workspace_root
      "" -> @default_workspace_root
      token -> anchor_on_workflow_dir(String.trim(token))
    end
  end

  defp resolve_workspace_root(_value), do: @default_workspace_root

  # `~` and an absolute path mean what they say. Everything else is a RELATIVE
  # path, relative to THE WORKFLOW FILE rather than to wherever the orchestrator
  # happened to be launched from — including a bare `workspaces` with no
  # separator in it, which is a directory name like any other. The one thing
  # left alone is a scheme-prefixed token (`env:NAME`, a URI): that is not a
  # path and never was ours to expand.
  defp anchor_on_workflow_dir("~" <> _rest = path), do: Path.expand(path)

  defp anchor_on_workflow_dir(path) when is_binary(path) do
    cond do
      Path.type(path) == :absolute ->
        Path.expand(path)

      scheme_prefixed?(path) ->
        path

      true ->
        workflow_dir = Workflow.workflow_file_path() |> Path.expand() |> Path.dirname()
        Path.expand(path, workflow_dir)
    end
  end

  defp scheme_prefixed?(path), do: String.match?(path, ~r/^[a-zA-Z][a-zA-Z0-9+.-]*:/)

  @spec workspace_hooks() :: workspace_hooks()
  def workspace_hooks do
    hooks = get_in(validated_workflow_options(), [:hooks])

    %{
      after_create: Map.get(hooks, :after_create),
      before_run: Map.get(hooks, :before_run),
      after_run: Map.get(hooks, :after_run),
      before_remove: Map.get(hooks, :before_remove),
      timeout_ms: Map.get(hooks, :timeout_ms)
    }
  end

  @spec hook_timeout_ms() :: pos_integer()
  def hook_timeout_ms do
    get_in(validated_workflow_options(), [:hooks, :timeout_ms])
  end

  @spec max_concurrent_agents() :: pos_integer()
  def max_concurrent_agents do
    get_in(validated_workflow_options(), [:agent, :max_concurrent_agents])
  end

  @spec max_retry_backoff_ms() :: pos_integer()
  def max_retry_backoff_ms do
    get_in(validated_workflow_options(), [:agent, :max_retry_backoff_ms])
  end

  @spec max_failure_retries() :: pos_integer()
  def max_failure_retries do
    get_in(validated_workflow_options(), [:agent, :max_failure_retries])
  end

  @spec agent_max_turns() :: pos_integer()
  def agent_max_turns do
    get_in(validated_workflow_options(), [:agent, :max_turns])
  end

  @spec max_dispatches_per_issue_per_day() :: pos_integer()
  def max_dispatches_per_issue_per_day do
    get_in(validated_workflow_options(), [:agent, :max_dispatches_per_issue_per_day])
  end

  @spec plan_cycle_repeat_limit() :: pos_integer()
  def plan_cycle_repeat_limit do
    get_in(validated_workflow_options(), [:agent, :plan_cycle_repeat_limit])
  end

  @spec max_concurrent_agents_for_state(term()) :: pos_integer()
  def max_concurrent_agents_for_state(state_name) when is_binary(state_name) do
    state_limits = get_in(validated_workflow_options(), [:agent, :max_concurrent_agents_by_state])
    global_limit = max_concurrent_agents()
    Map.get(state_limits, normalize_issue_state(state_name), global_limit)
  end

  def max_concurrent_agents_for_state(_state_name), do: max_concurrent_agents()

  @spec suitability_rules() :: %{
          skip_labels: [String.t()],
          require_description: boolean(),
          min_priority: pos_integer() | nil
        }
  def suitability_rules do
    opts = get_in(validated_workflow_options(), [:suitability])

    %{
      skip_labels: Map.get(opts, :skip_labels, []),
      require_description: Map.get(opts, :require_description, false),
      min_priority: Map.get(opts, :min_priority)
    }
  end

  @spec agent_backend() :: String.t()
  def agent_backend do
    get_in(validated_workflow_options(), [:agent, :backend])
  end

  @doc "Returns the agent runner module for the configured backend."
  @spec agent_runner_module() :: module()
  def agent_runner_module do
    case agent_backend() do
      "claude" -> SymphonyElixir.Claude.AgentRunner
      _ -> SymphonyElixir.AgentRunner
    end
  end

  # Claude Code config accessors

  @spec claude_command() :: String.t()
  def claude_command do
    get_in(validated_workflow_options(), [:claude, :command])
  end

  @spec claude_model() :: String.t() | nil
  def claude_model do
    get_in(validated_workflow_options(), [:claude, :model])
  end

  @doc "Model for the Plan (Planner) stage; falls back to `claude_model`."
  @spec claude_plan_model() :: String.t() | nil
  def claude_plan_model do
    get_in(validated_workflow_options(), [:claude, :plan_model]) || claude_model()
  end

  @doc "Model for the Test (tester sub-agent) stage; falls back to `claude_model`."
  @spec claude_test_model() :: String.t() | nil
  def claude_test_model do
    get_in(validated_workflow_options(), [:claude, :test_model]) || claude_model()
  end

  @doc "Model for the Grade (Grader) stage; falls back to `claude_model`."
  @spec claude_grade_model() :: String.t() | nil
  def claude_grade_model do
    get_in(validated_workflow_options(), [:claude, :grade_model]) || claude_model()
  end

  @doc "Model for the Fix CI stage; falls back to `claude_model`."
  @spec claude_fix_ci_model() :: String.t() | nil
  def claude_fix_ci_model do
    get_in(validated_workflow_options(), [:claude, :fix_ci_model]) || claude_model()
  end

  @spec claude_turn_timeout_ms() :: pos_integer()
  def claude_turn_timeout_ms do
    get_in(validated_workflow_options(), [:claude, :turn_timeout_ms])
  end

  @spec claude_stall_timeout_ms() :: non_neg_integer()
  def claude_stall_timeout_ms do
    validated_workflow_options()
    |> get_in([:claude, :stall_timeout_ms])
    |> max(0)
  end

  @spec claude_output_format() :: String.t()
  def claude_output_format do
    get_in(validated_workflow_options(), [:claude, :output_format])
  end

  @spec claude_max_turns() :: pos_integer()
  def claude_max_turns do
    get_in(validated_workflow_options(), [:claude, :max_turns])
  end

  @spec claude_permission_mode() :: String.t()
  def claude_permission_mode do
    get_in(validated_workflow_options(), [:claude, :permission_mode])
  end

  @spec claude_dangerously_skip_permissions?() :: boolean()
  def claude_dangerously_skip_permissions? do
    get_in(validated_workflow_options(), [:claude, :dangerously_skip_permissions])
  end

  @spec claude_allowed_tools() :: [String.t()] | nil
  def claude_allowed_tools do
    case get_in(validated_workflow_options(), [:claude, :allowed_tools]) do
      [] -> nil
      tools -> tools
    end
  end

  @spec claude_tmux_session_prefix() :: String.t()
  def claude_tmux_session_prefix do
    get_in(validated_workflow_options(), [:claude, :tmux_session_prefix])
  end

  @spec claude_tmux_width() :: pos_integer()
  def claude_tmux_width do
    get_in(validated_workflow_options(), [:claude, :tmux_width])
  end

  @spec claude_tmux_height() :: pos_integer()
  def claude_tmux_height do
    get_in(validated_workflow_options(), [:claude, :tmux_height])
  end

  @spec claude_tmux_startup_delay_ms() :: non_neg_integer()
  def claude_tmux_startup_delay_ms do
    get_in(validated_workflow_options(), [:claude, :tmux_startup_delay_ms])
  end

  @spec claude_tmux_paste_settle_ms() :: non_neg_integer()
  def claude_tmux_paste_settle_ms do
    get_in(validated_workflow_options(), [:claude, :tmux_paste_settle_ms])
  end

  @spec claude_tmux_ready_poll_interval_ms() :: pos_integer()
  def claude_tmux_ready_poll_interval_ms do
    get_in(validated_workflow_options(), [:claude, :tmux_ready_poll_interval_ms])
  end

  @spec claude_tmux_ready_timeout_ms() :: pos_integer()
  def claude_tmux_ready_timeout_ms do
    get_in(validated_workflow_options(), [:claude, :tmux_ready_timeout_ms])
  end

  @spec claude_tmux_jsonl_base_path() :: String.t()
  def claude_tmux_jsonl_base_path do
    get_in(validated_workflow_options(), [:claude, :tmux_jsonl_base_path])
  end

  @spec claude_tmux_jsonl_poll_interval_ms() :: pos_integer()
  def claude_tmux_jsonl_poll_interval_ms do
    get_in(validated_workflow_options(), [:claude, :tmux_jsonl_poll_interval_ms])
  end

  @spec codex_command() :: String.t()
  def codex_command do
    get_in(validated_workflow_options(), [:codex, :command])
  end

  @spec codex_turn_timeout_ms() :: pos_integer()
  def codex_turn_timeout_ms do
    get_in(validated_workflow_options(), [:codex, :turn_timeout_ms])
  end

  @spec codex_approval_policy() :: String.t() | map()
  def codex_approval_policy do
    case resolve_codex_approval_policy() do
      {:ok, approval_policy} -> approval_policy
      {:error, _reason} -> @default_codex_approval_policy
    end
  end

  @spec codex_thread_sandbox() :: String.t()
  def codex_thread_sandbox do
    case resolve_codex_thread_sandbox() do
      {:ok, thread_sandbox} -> thread_sandbox
      {:error, _reason} -> @default_codex_thread_sandbox
    end
  end

  @spec codex_turn_sandbox_policy(Path.t() | nil) :: map()
  def codex_turn_sandbox_policy(workspace \\ nil) do
    case resolve_codex_turn_sandbox_policy(workspace) do
      {:ok, turn_sandbox_policy} -> turn_sandbox_policy
      {:error, _reason} -> default_codex_turn_sandbox_policy(workspace)
    end
  end

  @spec codex_read_timeout_ms() :: pos_integer()
  def codex_read_timeout_ms do
    get_in(validated_workflow_options(), [:codex, :read_timeout_ms])
  end

  @spec codex_stall_timeout_ms() :: non_neg_integer()
  def codex_stall_timeout_ms do
    validated_workflow_options()
    |> get_in([:codex, :stall_timeout_ms])
    |> max(0)
  end

  @doc """
  The stall timeout the watchdog should use for the ACTIVE agent backend.

  The watchdog read `codex.stall_timeout_ms` whatever the backend was, so
  `claude.stall_timeout_ms` never reached it and a claude run was policed by a
  key describing a different runner. The only way to make the claude timeout
  effective was to set the codex key, which is how `WORKFLOW.md` ended up
  carrying a 30-minute `codex.stall_timeout_ms` for a claude-only orchestrator
  (TODO.md "Stall watchdog counts before_run provisioning as agent inactivity").
  """
  @spec agent_stall_timeout_ms() :: non_neg_integer()
  def agent_stall_timeout_ms do
    case agent_backend() do
      "claude" -> claude_stall_timeout_ms()
      _ -> codex_stall_timeout_ms()
    end
  end

  @spec workflow_prompt() :: String.t()
  def workflow_prompt do
    case current_workflow() do
      {:ok, %{prompt_template: prompt}} ->
        if String.trim(prompt) == "", do: @default_prompt_template, else: prompt

      _ ->
        @default_prompt_template
    end
  end

  @spec observability_enabled?() :: boolean()
  def observability_enabled? do
    get_in(validated_workflow_options(), [:observability, :dashboard_enabled])
  end

  @spec observability_refresh_ms() :: pos_integer()
  def observability_refresh_ms do
    get_in(validated_workflow_options(), [:observability, :refresh_ms])
  end

  @spec observability_render_interval_ms() :: pos_integer()
  def observability_render_interval_ms do
    get_in(validated_workflow_options(), [:observability, :render_interval_ms])
  end

  @spec server_port() :: non_neg_integer() | nil
  def server_port do
    case Application.get_env(:symphony_elixir, :server_port_override) do
      port when is_integer(port) and port >= 0 ->
        port

      _ ->
        get_in(validated_workflow_options(), [:server, :port])
    end
  end

  @spec server_host() :: String.t()
  def server_host do
    get_in(validated_workflow_options(), [:server, :host])
  end

  # Escalation config accessors

  @spec escalation_eval_score_threshold() :: integer()
  def escalation_eval_score_threshold do
    get_in(validated_workflow_options(), [:escalation, :eval_score_threshold])
  end

  @spec escalation_webhook_url() :: String.t() | nil
  def escalation_webhook_url do
    get_in(validated_workflow_options(), [:escalation, :webhook_url])
  end

  @spec escalation_needs_human_state() :: String.t() | nil
  def escalation_needs_human_state do
    get_in(validated_workflow_options(), [:escalation, :needs_human_state])
  end

  @spec validate!() :: :ok | {:error, term()}
  def validate! do
    with {:ok, _workflow} <- current_workflow(),
         :ok <- require_tracker_kind(),
         :ok <- require_linear_token(),
         :ok <- require_linear_target() do
      case agent_backend() do
        "claude" -> require_claude_command()
        _ -> with(:ok <- require_valid_codex_runtime_settings(), do: require_codex_command())
      end
    end
  end

  @spec codex_runtime_settings(Path.t() | nil) :: {:ok, codex_runtime_settings()} | {:error, term()}
  def codex_runtime_settings(workspace \\ nil) do
    with {:ok, approval_policy} <- resolve_codex_approval_policy(),
         {:ok, thread_sandbox} <- resolve_codex_thread_sandbox(),
         {:ok, turn_sandbox_policy} <- resolve_codex_turn_sandbox_policy(workspace) do
      {:ok,
       %{
         approval_policy: approval_policy,
         thread_sandbox: thread_sandbox,
         turn_sandbox_policy: turn_sandbox_policy
       }}
    end
  end

  defp require_tracker_kind do
    case tracker_kind() do
      "linear" -> :ok
      "memory" -> :ok
      nil -> {:error, :missing_tracker_kind}
      other -> {:error, {:unsupported_tracker_kind, other}}
    end
  end

  defp require_linear_token do
    case tracker_kind() do
      "linear" ->
        if is_binary(linear_api_token()) do
          :ok
        else
          {:error, :missing_linear_api_token}
        end

      _ ->
        :ok
    end
  end

  defp require_linear_target do
    case tracker_kind() do
      "linear" ->
        filter = linear_filter()

        if SymphonyElixir.Linear.FilterBuilder.valid?(filter) do
          :ok
        else
          {:error, :missing_linear_filter}
        end

      _ ->
        :ok
    end
  end

  defp require_codex_command do
    if byte_size(String.trim(codex_command())) > 0 do
      :ok
    else
      {:error, :missing_codex_command}
    end
  end

  defp require_claude_command do
    if byte_size(String.trim(claude_command())) > 0 do
      :ok
    else
      {:error, :missing_claude_command}
    end
  end

  defp require_valid_codex_runtime_settings do
    case codex_runtime_settings() do
      {:ok, _settings} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp validated_workflow_options do
    workflow_config()
    |> extract_workflow_options()
    |> NimbleOptions.validate!(@workflow_options_schema)
  end

  defp extract_workflow_options(config) do
    %{
      tracker: extract_tracker_options(section_map(config, "tracker")),
      polling: extract_polling_options(section_map(config, "polling")),
      workspace: extract_workspace_options(section_map(config, "workspace")),
      agent: extract_agent_options(section_map(config, "agent")),
      suitability: extract_suitability_options(section_map(config, "suitability")),
      codex: extract_codex_options(section_map(config, "codex")),
      claude: extract_claude_options(section_map(config, "claude")),
      hooks: extract_hooks_options(section_map(config, "hooks")),
      observability: extract_observability_options(section_map(config, "observability")),
      server: extract_server_options(section_map(config, "server")),
      escalation: extract_escalation_options(section_map(config, "escalation"))
    }
  end

  defp extract_tracker_options(section) do
    %{}
    |> put_if_present(:kind, normalize_tracker_kind(scalar_string_value(Map.get(section, "kind"))))
    |> put_if_present(:endpoint, scalar_string_value(Map.get(section, "endpoint")))
    |> put_if_present(:api_key, binary_value(Map.get(section, "api_key"), allow_empty: true))
    |> put_if_present(:filter, map_value(Map.get(section, "filter")))
    |> put_if_present(:assignee, scalar_string_value(Map.get(section, "assignee")))
    |> put_if_present(:claim_assignee, scalar_string_value(Map.get(section, "claim_assignee")))
    |> put_if_present(:active_states, csv_value(Map.get(section, "active_states")))
    |> put_if_present(:terminal_states, csv_value(Map.get(section, "terminal_states")))
  end

  defp extract_polling_options(section) do
    %{}
    |> put_if_present(:interval_ms, integer_value(Map.get(section, "interval_ms")))
    |> put_if_present(:active_hours, extract_active_hours(section_map(section, "active_hours")))
  end

  defp extract_active_hours(section) do
    %{}
    |> put_if_present(:start, integer_value(Map.get(section, "start")))
    |> put_if_present(:end, integer_value(Map.get(section, "end")))
    |> put_if_present(:timezone, scalar_string_value(Map.get(section, "timezone")))
  end

  defp extract_workspace_options(section) do
    %{}
    |> put_if_present(:root, binary_value(Map.get(section, "root")))
  end

  defp extract_agent_options(section) do
    %{}
    |> put_if_present(:backend, scalar_string_value(Map.get(section, "backend")))
    |> put_if_present(:max_concurrent_agents, integer_value(Map.get(section, "max_concurrent_agents")))
    |> put_if_present(:max_turns, positive_integer_value(Map.get(section, "max_turns")))
    |> put_if_present(:max_retry_backoff_ms, positive_integer_value(Map.get(section, "max_retry_backoff_ms")))
    |> put_if_present(:max_failure_retries, positive_integer_value(Map.get(section, "max_failure_retries")))
    |> put_if_present(
      :max_concurrent_agents_by_state,
      state_limits_value(Map.get(section, "max_concurrent_agents_by_state"))
    )
  end

  defp extract_suitability_options(section) do
    %{}
    |> put_if_present(:skip_labels, csv_value(Map.get(section, "skip_labels")))
    |> put_if_present(:require_description, boolean_value(Map.get(section, "require_description")))
    |> put_if_present(:min_priority, positive_integer_value(Map.get(section, "min_priority")))
  end

  defp extract_codex_options(section) do
    %{}
    |> put_if_present(:command, command_value(Map.get(section, "command")))
    |> put_if_present(:turn_timeout_ms, integer_value(Map.get(section, "turn_timeout_ms")))
    |> put_if_present(:read_timeout_ms, integer_value(Map.get(section, "read_timeout_ms")))
    |> put_if_present(:stall_timeout_ms, integer_value(Map.get(section, "stall_timeout_ms")))
  end

  defp extract_claude_options(section) do
    %{}
    |> put_if_present(:command, command_value(Map.get(section, "command")))
    |> put_if_present(:model, scalar_string_value(Map.get(section, "model")))
    # command_value (not scalar_string_value) so a blank/whitespace-only value
    # becomes :omit and the getter falls back to claude_model/0 — an empty
    # string is truthy, so `get_in(...) || claude_model()` would not.
    |> put_if_present(:plan_model, command_value(Map.get(section, "plan_model")))
    |> put_if_present(:test_model, command_value(Map.get(section, "test_model")))
    |> put_if_present(:grade_model, command_value(Map.get(section, "grade_model")))
    |> put_if_present(:fix_ci_model, command_value(Map.get(section, "fix_ci_model")))
    |> put_if_present(:turn_timeout_ms, integer_value(Map.get(section, "turn_timeout_ms")))
    |> put_if_present(:stall_timeout_ms, integer_value(Map.get(section, "stall_timeout_ms")))
    |> put_if_present(:output_format, scalar_string_value(Map.get(section, "output_format")))
    |> put_if_present(:max_turns, positive_integer_value(Map.get(section, "max_turns")))
    |> put_if_present(:permission_mode, scalar_string_value(Map.get(section, "permission_mode")))
    |> put_if_present(:dangerously_skip_permissions, boolean_value(Map.get(section, "dangerously_skip_permissions")))
    |> put_if_present(:allowed_tools, csv_value(Map.get(section, "allowed_tools")))
    |> put_if_present(:tmux_session_prefix, scalar_string_value(Map.get(section, "tmux_session_prefix")))
    |> put_if_present(:tmux_width, positive_integer_value(Map.get(section, "tmux_width")))
    |> put_if_present(:tmux_height, positive_integer_value(Map.get(section, "tmux_height")))
    |> put_if_present(:tmux_startup_delay_ms, integer_value(Map.get(section, "tmux_startup_delay_ms")))
    |> put_if_present(:tmux_paste_settle_ms, integer_value(Map.get(section, "tmux_paste_settle_ms")))
    |> put_if_present(:tmux_ready_poll_interval_ms, positive_integer_value(Map.get(section, "tmux_ready_poll_interval_ms")))
    |> put_if_present(:tmux_ready_timeout_ms, positive_integer_value(Map.get(section, "tmux_ready_timeout_ms")))
    |> put_if_present(:tmux_jsonl_base_path, scalar_string_value(Map.get(section, "tmux_jsonl_base_path")))
    |> put_if_present(:tmux_jsonl_poll_interval_ms, positive_integer_value(Map.get(section, "tmux_jsonl_poll_interval_ms")))
  end

  defp extract_hooks_options(section) do
    %{}
    |> put_if_present(:after_create, hook_command_value(Map.get(section, "after_create")))
    |> put_if_present(:before_run, hook_command_value(Map.get(section, "before_run")))
    |> put_if_present(:after_run, hook_command_value(Map.get(section, "after_run")))
    |> put_if_present(:before_remove, hook_command_value(Map.get(section, "before_remove")))
    |> put_if_present(:timeout_ms, positive_integer_value(Map.get(section, "timeout_ms")))
  end

  defp extract_observability_options(section) do
    %{}
    |> put_if_present(:dashboard_enabled, boolean_value(Map.get(section, "dashboard_enabled")))
    |> put_if_present(:refresh_ms, integer_value(Map.get(section, "refresh_ms")))
    |> put_if_present(:render_interval_ms, integer_value(Map.get(section, "render_interval_ms")))
  end

  defp extract_server_options(section) do
    %{}
    |> put_if_present(:port, non_negative_integer_value(Map.get(section, "port")))
    |> put_if_present(:host, scalar_string_value(Map.get(section, "host")))
  end

  defp extract_escalation_options(section) do
    %{}
    |> put_if_present(:eval_score_threshold, integer_value(Map.get(section, "eval_score_threshold")))
    |> put_if_present(:webhook_url, scalar_string_value(Map.get(section, "webhook_url")))
    |> put_if_present(:needs_human_state, scalar_string_value(Map.get(section, "needs_human_state")))
  end

  defp section_map(config, key) do
    case Map.get(config, key) do
      section when is_map(section) -> section
      _ -> %{}
    end
  end

  defp put_if_present(map, _key, :omit), do: map
  defp put_if_present(map, key, value), do: Map.put(map, key, value)

  defp scalar_string_value(nil), do: :omit
  defp scalar_string_value(value) when is_binary(value), do: String.trim(value)
  defp scalar_string_value(value) when is_boolean(value), do: to_string(value)
  defp scalar_string_value(value) when is_integer(value), do: to_string(value)
  defp scalar_string_value(value) when is_float(value), do: to_string(value)
  defp scalar_string_value(value) when is_atom(value), do: Atom.to_string(value)
  defp scalar_string_value(_value), do: :omit

  defp binary_value(value, opts \\ [])

  defp binary_value(value, opts) when is_binary(value) do
    allow_empty = Keyword.get(opts, :allow_empty, false)

    if value == "" and not allow_empty do
      :omit
    else
      value
    end
  end

  defp binary_value(_value, _opts), do: :omit

  defp command_value(value) when is_binary(value) do
    case String.trim(value) do
      "" -> :omit
      trimmed -> trimmed
    end
  end

  defp command_value(_value), do: :omit

  defp hook_command_value(value) when is_binary(value) do
    case String.trim(value) do
      "" -> :omit
      _ -> String.trim_trailing(value)
    end
  end

  defp hook_command_value(_value), do: :omit

  defp csv_value(values) when is_list(values) do
    values
    |> Enum.reduce([], fn value, acc -> maybe_append_csv_value(acc, value) end)
    |> Enum.reverse()
    |> case do
      [] -> :omit
      normalized_values -> normalized_values
    end
  end

  defp csv_value(value) when is_binary(value) do
    value
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> case do
      [] -> :omit
      normalized_values -> normalized_values
    end
  end

  defp csv_value(_value), do: :omit

  defp maybe_append_csv_value(acc, value) do
    case scalar_string_value(value) do
      :omit ->
        acc

      normalized ->
        append_csv_value_if_present(acc, normalized)
    end
  end

  defp append_csv_value_if_present(acc, value) do
    trimmed = String.trim(value)

    if trimmed == "" do
      acc
    else
      [trimmed | acc]
    end
  end

  defp integer_value(value) do
    case parse_integer(value) do
      {:ok, parsed} -> parsed
      :error -> :omit
    end
  end

  defp positive_integer_value(value) do
    case parse_positive_integer(value) do
      {:ok, parsed} -> parsed
      :error -> :omit
    end
  end

  defp non_negative_integer_value(value) do
    case parse_non_negative_integer(value) do
      {:ok, parsed} -> parsed
      :error -> :omit
    end
  end

  defp map_value(value) when is_map(value) and map_size(value) > 0, do: value
  defp map_value(_value), do: :omit

  defp boolean_value(value) when is_boolean(value), do: value

  defp boolean_value(value) when is_binary(value) do
    case String.downcase(String.trim(value)) do
      "true" -> true
      "false" -> false
      _ -> :omit
    end
  end

  defp boolean_value(_value), do: :omit

  defp state_limits_value(value) when is_map(value) do
    value
    |> Enum.reduce(%{}, fn {state_name, limit}, acc ->
      case parse_positive_integer(limit) do
        {:ok, parsed} ->
          Map.put(acc, normalize_issue_state(to_string(state_name)), parsed)

        :error ->
          acc
      end
    end)
  end

  defp state_limits_value(_value), do: :omit

  defp parse_integer(value) when is_integer(value), do: {:ok, value}

  defp parse_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, _} -> {:ok, parsed}
      :error -> :error
    end
  end

  defp parse_integer(_value), do: :error

  defp parse_positive_integer(value) do
    case parse_integer(value) do
      {:ok, parsed} when parsed > 0 -> {:ok, parsed}
      _ -> :error
    end
  end

  defp parse_non_negative_integer(value) do
    case parse_integer(value) do
      {:ok, parsed} when parsed >= 0 -> {:ok, parsed}
      _ -> :error
    end
  end

  defp fetch_value(paths, default) do
    config = workflow_config()

    case resolve_config_value(config, paths) do
      :missing -> default
      value -> value
    end
  end

  defp resolve_codex_approval_policy do
    case fetch_value([["codex", "approval_policy"]], :missing) do
      :missing ->
        {:ok, @default_codex_approval_policy}

      nil ->
        {:ok, @default_codex_approval_policy}

      value when is_binary(value) ->
        approval_policy = String.trim(value)

        if approval_policy == "" do
          {:error, {:invalid_codex_approval_policy, value}}
        else
          {:ok, approval_policy}
        end

      value when is_map(value) ->
        {:ok, value}

      value ->
        {:error, {:invalid_codex_approval_policy, value}}
    end
  end

  defp resolve_codex_thread_sandbox do
    case fetch_value([["codex", "thread_sandbox"]], :missing) do
      :missing ->
        {:ok, @default_codex_thread_sandbox}

      nil ->
        {:ok, @default_codex_thread_sandbox}

      value when is_binary(value) ->
        thread_sandbox = String.trim(value)

        if thread_sandbox == "" do
          {:error, {:invalid_codex_thread_sandbox, value}}
        else
          {:ok, thread_sandbox}
        end

      value ->
        {:error, {:invalid_codex_thread_sandbox, value}}
    end
  end

  defp resolve_codex_turn_sandbox_policy(workspace) do
    case fetch_value([["codex", "turn_sandbox_policy"]], :missing) do
      :missing ->
        {:ok, default_codex_turn_sandbox_policy(workspace)}

      nil ->
        {:ok, default_codex_turn_sandbox_policy(workspace)}

      value when is_map(value) ->
        {:ok, value}

      value ->
        {:error, {:invalid_codex_turn_sandbox_policy, {:unsupported_value, value}}}
    end
  end

  defp default_codex_turn_sandbox_policy(workspace) do
    writable_root =
      if is_binary(workspace) and String.trim(workspace) != "" do
        Path.expand(workspace)
      else
        Path.expand(workspace_root())
      end

    %{
      "type" => "workspaceWrite",
      "writableRoots" => [writable_root],
      "readOnlyAccess" => %{"type" => "fullAccess"},
      "networkAccess" => false,
      "excludeTmpdirEnvVar" => false,
      "excludeSlashTmp" => false
    }
  end

  defp normalize_issue_state(state_name) when is_binary(state_name) do
    state_name
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_tracker_kind(kind) when is_binary(kind) do
    kind
    |> String.trim()
    |> String.downcase()
    |> case do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_tracker_kind(_kind), do: nil

  defp workflow_config do
    case current_workflow() do
      {:ok, %{config: config}} when is_map(config) ->
        normalize_keys(config)

      _ ->
        %{}
    end
  end

  defp resolve_config_value(%{} = config, paths) do
    Enum.reduce_while(paths, :missing, fn path, _acc ->
      case get_in_path(config, path) do
        :missing -> {:cont, :missing}
        value -> {:halt, value}
      end
    end)
  end

  defp get_in_path(config, path) when is_list(path) and is_map(config) do
    get_in_path(config, path, 0)
  end

  defp get_in_path(_, _), do: :missing

  defp get_in_path(config, [], _depth), do: config

  defp get_in_path(%{} = current, [segment | rest], _depth) do
    case Map.fetch(current, normalize_key(segment)) do
      {:ok, value} -> get_in_path(value, rest, 0)
      :error -> :missing
    end
  end

  defp get_in_path(_, _, _depth), do: :missing

  defp normalize_keys(value) when is_map(value) do
    Enum.reduce(value, %{}, fn {key, raw_value}, normalized ->
      Map.put(normalized, normalize_key(key), normalize_keys(raw_value))
    end)
  end

  defp normalize_keys(value) when is_list(value), do: Enum.map(value, &normalize_keys/1)
  defp normalize_keys(value), do: value

  defp normalize_key(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_key(value), do: to_string(value)

  defp resolve_env_value(:missing, fallback), do: fallback
  defp resolve_env_value(nil, fallback), do: fallback

  defp resolve_env_value(value, fallback) when is_binary(value) do
    trimmed = String.trim(value)

    case env_reference_name(trimmed) do
      {:ok, env_name} ->
        env_name
        |> System.get_env()
        |> then(fn
          nil -> fallback
          "" -> nil
          env_value -> env_value
        end)

      :error ->
        trimmed
    end
  end

  defp resolve_env_value(_value, fallback), do: fallback

  defp normalize_path_token(value) when is_binary(value) do
    trimmed = String.trim(value)

    case env_reference_name(trimmed) do
      {:ok, env_name} -> resolve_env_token(env_name)
      :error -> trimmed
    end
  end

  defp env_reference_name("$" <> env_name) do
    if String.match?(env_name, ~r/^[A-Za-z_][A-Za-z0-9_]*$/) do
      {:ok, env_name}
    else
      :error
    end
  end

  defp env_reference_name(_value), do: :error

  defp resolve_env_token(value) do
    case System.get_env(value) do
      nil -> :missing
      env_value -> env_value
    end
  end

  defp normalize_secret_value(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_secret_value(_value), do: nil
end
