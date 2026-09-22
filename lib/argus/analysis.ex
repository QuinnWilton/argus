defmodule Argus.Analysis do
  @moduledoc """
  Behaviour and API for BEAM program analyses.

  Each analysis is a module that implements this behaviour, declaring its
  name, description, Souffle rules file, required extractors, and output
  relations. The system discovers these modules at runtime from the
  `:panoptes` application's module list.

  ## Defining a custom analysis

  Create a module that implements `@behaviour Argus.Analysis`:

      defmodule MyApp.Analyses.Unused do
        @behaviour Argus.Analysis

        @impl true
        def name, do: :unused

        @impl true
        def description, do: "find unused functions"

        @impl true
        def rules_file, do: "unused.dl"

        @impl true
        def extractors, do: []

        @impl true
        def output_relations do
          [
            %{
              name: :unused_function,
              fields: [{:func, :symbol, "function ID"}],
              doc: "Function that is never called."
            }
          ]
        end
      end

  You can also pass `{:custom, "path/to/rules.dl"}` to `run/3` to run
  ad-hoc Datalog rules without defining a module.

  ## Built-in analyses

  See modules under `Argus.Analyses.*` for the full list. Use
  `builtin_analyses/0` or `builtin_analysis_modules/0` to discover them
  at runtime.
  """

  alias Argus.Pipeline
  alias Argus.Souffle

  # Behaviour callbacks.

  @type output_relation :: %{
          required(:name) => atom(),
          required(:fields) => [Argus.Schema.field()],
          required(:doc) => String.t(),
          optional(:key) => [atom()]
        }

  @callback name() :: atom()
  @callback description() :: String.t()
  @callback rules_file() :: String.t()
  @callback extractors() :: [module()]
  @callback output_relations() :: [output_relation()]

  @doc """
  Converts one output-relation row into finding attributes.

  Receives the relation name (as declared in `output_relations/0`) and the
  raw row (a list of strings, one per declared field). Implementations
  assign a severity, write title/detail prose, and attach the most precise
  anchor the row allows — see `Argus.Findings` for the construction
  helpers. Optional: analyses without it fall back to a generic
  `:info`-severity rendering of the relation's declared doc.

  Relations that carry witness columns (a call site that evidences the
  defect) can produce several rows for one logical finding — one per
  witnessing site. Such a relation declares `:key`: the field names that
  identify the finding. Rows agreeing on the key fields are deduplicated
  before conversion, and `finding/2` receives one deterministic
  representative (the lexicographically least row), so finding counts do
  not depend on how many sites witness the same defect.
  """
  @callback finding(relation :: atom(), row :: [String.t()]) :: Argus.Findings.attrs()

  @optional_callbacks finding: 2

  # Public API types.

  @type analysis :: atom() | {:custom, Path.t()}
  @type result :: %{String.t() => [[String.t()]]}

  @typedoc """
  One piece of an alias: rows of `relation` in `analysis` whose columns
  match `where` (a keyword of column name to a value or list of values)
  are what the old analysis name used to report.
  """
  @type alias_entry :: %{analysis: atom(), relation: atom(), where: keyword()}

  # ── Concerns, sets and aliases ──────────────────────────────────────
  #
  # An analysis answers "what goes wrong". Mechanism (rpc vs
  # GenServer.call), phase (init vs terminate) and proximity (export vs
  # request-direct) are columns on a relation, never separate analyses;
  # a defect has one owner. The names below are that axis.

  @concerns [
    :startup,
    :shutdown,
    :blocking,
    :coupling,
    :mailbox,
    :failure,
    :structure,
    :state_machine,
    :ets,
    :effects,
    :unsafe_input,
    :exposure,
    :coverage
  ]

  # The analyses each retired name's findings live in now, with the rows
  # that were its. `Argus.Findings.run/2` accepts the old name for two
  # minor versions, runs the new analysis, keeps the rows listed here and
  # reports them under the old name with `concern` set to the new one.
  @aliases %{
    atom_safety: [
      %{analysis: :unsafe_input, relation: :sink_without_request_path, where: []}
    ],
    request_surface: [
      %{analysis: :unsafe_input, relation: :sink_reachable, where: []},
      %{analysis: :unsafe_input, relation: :sink_endpoint, where: []}
    ],
    unbounded_dynamic_children: [
      %{analysis: :unsafe_input, relation: :unbounded_children_from_request, where: []}
    ],
    secret_exposure: [%{analysis: :exposure, relation: :unredacted_secret, where: []}],
    tls_verification: [
      %{analysis: :exposure, relation: :disables_verification, where: []},
      %{analysis: :exposure, relation: :relies_on_default_verification, where: []}
    ],
    purity: [
      %{analysis: :effects, relation: :effect_in_context, where: [context: "pure_contract"]},
      %{analysis: :effects, relation: :purity_unprovable, where: []},
      %{analysis: :effects, relation: :impure_closure_to_pure, where: []},
      %{analysis: :effects, relation: :purity_verified, where: []}
    ],
    transaction_safety: [
      %{analysis: :effects, relation: :effect_in_context, where: [context: "transaction"]}
    ],
    timeout_chain: [
      %{analysis: :blocking, relation: :timeout_chain_risk, where: []},
      %{analysis: :blocking, relation: :blocking_cast_handler, where: []},
      %{analysis: :blocking, relation: :timeout_insufficient, where: []},
      %{analysis: :blocking, relation: :infinity_timeout_in_chain, where: []}
    ],
    call_cycle: [
      %{analysis: :blocking, relation: :call_cycle, where: []},
      %{analysis: :blocking, relation: :call_cycle_path, where: []}
    ],
    process_bottleneck: [
      %{analysis: :blocking, relation: :sync_call_fan_in, where: []},
      %{analysis: :blocking, relation: :bottleneck_caller, where: []}
    ],
    callback_receive: [
      %{analysis: :blocking, relation: :blocking_receive_in_callback, where: []},
      %{analysis: :blocking, relation: :receive_in_callback, where: []}
    ],
    one_for_one_coupling: [
      %{analysis: :coupling, relation: :sibling_dependency, where: [reason: "restart_isolation"]}
    ],
    sync_call_in_init: [
      %{analysis: :startup, relation: :sync_call_in_init, where: []},
      %{analysis: :startup, relation: :init_deadlock_risk, where: []},
      %{analysis: :startup, relation: :sup_call_in_init, where: []},
      %{analysis: :startup, relation: :init_waits_on_blocking_server, where: []},
      %{analysis: :startup, relation: :blocking_recv_in_init, where: []},
      %{analysis: :startup, relation: :connect_in_init_without_backoff, where: []}
    ],
    deferred_startup_deadlock: [
      %{analysis: :startup, relation: :mutual_continue_deadlock, where: []},
      %{analysis: :startup, relation: :continue_to_later_sibling, where: []},
      %{analysis: :startup, relation: :continue_to_parent_supervisor, where: []},
      %{analysis: :startup, relation: :init_timeout_deferral, where: []},
      %{analysis: :startup, relation: :continue_crash_loop_risk, where: []}
    ],
    shutdown_safety: [
      %{analysis: :shutdown, relation: :cleanup_never_runs, where: []},
      %{analysis: :shutdown, relation: :cleanup_unclear, where: []},
      %{analysis: :shutdown, relation: :terminate_may_be_truncated, where: []},
      %{analysis: :shutdown, relation: :terminate_calls_sibling, where: []},
      %{analysis: :shutdown, relation: :callback_stops_sibling, where: []},
      %{analysis: :shutdown, relation: :foreign_dynamic_children, where: []}
    ],
    supervision: [
      %{analysis: :coupling, relation: :sibling_dependency, where: [reason: "restart_policy"]},
      %{analysis: :coupling, relation: :sibling_dependency, where: [reason: "cached_pid"]},
      %{analysis: :coupling, relation: :rest_for_one_orphaned_children, where: []},
      %{analysis: :coupling, relation: :dual_restart_authority, where: []},
      %{analysis: :structure, relation: :supervisor_registered_as_worker, where: []},
      %{analysis: :structure, relation: :consumer_supervisor_permanent_child, where: []},
      %{analysis: :startup, relation: :wrong_start_order, where: []},
      %{analysis: :startup, relation: :post_start_initialization, where: []},
      %{analysis: :shutdown, relation: :permanent_child_stops_normally, where: []}
    ],
    distributed: [
      %{analysis: :blocking, relation: :rpc_without_timeout, where: []},
      %{analysis: :blocking, relation: :rpc_in_genserver_callback, where: []},
      %{analysis: :blocking, relation: :global_blocking_op, where: []},
      %{analysis: :structure, relation: :global_register_risk, where: []},
      %{analysis: :startup, relation: :global_blocking_in_init, where: []},
      %{analysis: :startup, relation: :distributed_in_init, where: []},
      %{analysis: :failure, relation: :erpc_transport_unhandled, where: []},
      %{analysis: :failure, relation: :rpc_result_unhandled, where: []}
    ],
    unlinked_spawn: [%{analysis: :failure, relation: :unlinked_spawn, where: []}],
    process_registry: [
      %{analysis: :structure, relation: :duplicate_process_name, where: []},
      %{analysis: :failure, relation: :whereis_race, where: []}
    ],
    error_handling: [
      %{analysis: :blocking, relation: :partial_noproc_catch, where: []},
      %{analysis: :startup, relation: :ignored_start_result, where: []},
      %{analysis: :shutdown, relation: :trap_exit_without_handler, where: []},
      %{analysis: :shutdown, relation: :trap_exit_without_exit_clause, where: []},
      %{analysis: :failure, relation: :swallowed_error, where: []},
      %{analysis: :failure, relation: :exit_in_callback, where: []},
      %{analysis: :mailbox, relation: :handle_info_without_catchall, where: []},
      %{analysis: :mailbox, relation: :handle_info_partial, where: []},
      %{analysis: :mailbox, relation: :timer_cancel_without_flush, where: []}
    ],
    unsafe_task: [
      %{analysis: :failure, relation: :unchecked_start_child, where: []},
      %{analysis: :mailbox, relation: :nolink_messages_unhandled, where: []},
      %{analysis: :mailbox, relation: :leaked_async_task, where: []},
      %{analysis: :mailbox, relation: :yield_on_linked_task, where: []},
      %{analysis: :mailbox, relation: :linked_task_in_library, where: []}
    ],
    monitor_leak: [
      %{analysis: :shutdown, relation: :deliberate_termination_while_monitored, where: []},
      %{analysis: :mailbox, relation: :leaked_monitor, where: []},
      %{analysis: :mailbox, relation: :monitor_never_released, where: []},
      %{analysis: :mailbox, relation: :monitor_ref_discarded, where: []}
    ],
    message_contract: [%{analysis: :mailbox, relation: :unhandled_self_message, where: []}],
    reply_contract: [%{analysis: :mailbox, relation: :never_replies, where: []}],
    gen_statem: [
      %{analysis: :mailbox, relation: :state_missing_info_catchall, where: []},
      %{analysis: :mailbox, relation: :statem_timeout_unhandled, where: []},
      %{analysis: :mailbox, relation: :call_never_replied, where: []},
      %{analysis: :state_machine, relation: :unreachable_state, where: []},
      %{analysis: :state_machine, relation: :terminal_without_stop, where: []}
    ]
  }

  @doc "The concern vocabulary: every built-in analysis is named after one."
  @spec concerns() :: [atom()]
  def concerns, do: @concerns

  @doc """
  The retired analysis names and where their findings live now.
  """
  @spec aliases() :: %{atom() => [alias_entry()]}
  def aliases, do: @aliases

  @doc """
  Where a retired analysis name's findings live now: `{:ok, entries}`,
  or `:error` for a name that never was an analysis.
  """
  @spec alias(atom()) :: {:ok, [alias_entry()]} | :error
  def alias(name) when is_atom(name), do: Map.fetch(@aliases, name)

  @doc """
  The named sets of analyses `Argus.run_analyses/2` accepts in place of a
  list: `:all` (every built-in but `:coverage`, which measures the
  extractor pipeline rather than the code), `:default` (what scry runs
  without configuration), `:security`, `:effects` and `:otp` (everything
  else).
  """
  @spec sets() :: %{atom() => [atom()]}
  def sets do
    all = builtin_analyses() -- [:coverage]
    security = Enum.filter([:unsafe_input, :exposure], &(&1 in all))
    effects = Enum.filter([:effects], &(&1 in all))

    %{
      all: all,
      default: Enum.filter(default_set(), &(&1 in all)),
      security: security,
      effects: effects,
      otp: all -- (security ++ effects)
    }
  end

  # scry's default until the regroup completes; the concern analyses
  # replace these names as they land.
  defp default_set do
    [
      :startup,
      :coupling,
      :shutdown,
      :structure,
      :failure,
      :mailbox
    ]
  end

  @doc "The analyses in a named set: `{:ok, names}` or `:error`."
  @spec set(atom()) :: {:ok, [atom()]} | :error
  def set(name) when is_atom(name), do: Map.fetch(sets(), name)

  @doc """
  Runs an analysis against the given modules.

  Returns `{:ok, results}` where results is a map of relation name to
  list of rows. Each row is a list of strings.

  ## Options

  - `:concurrency` — number of parallel extraction workers (default: schedulers)
  - `:extractors` — list of domain extractor modules to run
  - `:souffle_bin` — path to souffle binary (default: auto-detect)
  """
  @spec run(modules :: [atom() | String.t()], analysis(), keyword()) ::
          {:ok, result()} | {:error, term()}
  def run(modules, analysis, opts \\ []) do
    with {:ok, rules_path} <- resolve_rules(analysis),
         {:ok, facts_dir} <- extract_facts(modules, [analysis], opts) do
      try do
        with {:ok, results} <- Souffle.run(facts_dir, rules_path, opts) do
          {:ok, filter_to_outputs(results, analysis)}
        end
      after
        File.rm_rf(Path.dirname(facts_dir))
      end
    end
  end

  @doc """
  Extracts facts from the given modules once, for one or more analyses.

  Runs the pipeline with the union of the analyses' default extractors
  (plus any extra `:extractors` from `opts`), writing `.facts` files to a
  fresh temporary directory. Because the pipeline always materializes
  every schema relation (empty files included), the resulting directory
  can feed `run_rules/3` for each of the analyses without re-extraction.

  Returns `{:ok, facts_dir}` or `{:error, reason}`.
  """
  @spec extract_facts(modules :: [atom() | String.t()], [analysis()], keyword()) ::
          {:ok, Path.t()} | {:error, term()}
  def extract_facts(modules, analyses, opts \\ []) do
    default_extractors =
      analyses
      |> Enum.flat_map(&default_extractors_for/1)
      |> Enum.uniq()

    opts =
      opts
      |> Keyword.update(:extractors, default_extractors, &Enum.uniq(default_extractors ++ &1))
      |> Keyword.put_new(:relations, staged_relations(analyses))
      |> maybe_enable_imprecision_tracing(analyses)

    with {:ok, work_dir} <- create_work_dir(),
         facts_dir = Path.join(work_dir, "facts"),
         {:ok, _} <- Pipeline.run(modules, facts_dir, opts),
         :ok <- derive_stage0(facts_dir, opts) do
      {:ok, facts_dir}
    end
  end

  # The built-in programs never read the in-process-only relations, so the
  # staged directory leaves them empty. A custom program might, and there
  # is no declaration to consult without running Souffle, so it gets
  # everything.
  defp staged_relations(analyses) do
    if Enum.any?(analyses, &match?({:custom, _}, &1)) do
      :all
    else
      Argus.Schema.names() -- Argus.Schema.in_process_only()
    end
  end

  @doc """
  Derives the stage-0 relations into an existing facts directory.

  Stage 0 is the shared call graph (`call_edge`): every client analysis
  needs it, and before stratification each one re-derived it inside its
  own solve from the layer-1 bytecode relations. Deriving it once here
  removes that redundancy, and — more importantly for incremental
  consumers — keeps `instruction`, `remote_call` and friends out of the
  input set of analyses that only reason about supervision structure.

  `extract_facts/3` calls this for you, so batch callers need not think
  about it. Incremental consumers call it directly, memoize the result,
  and reuse it across solves: the output is markedly more stable than its
  inputs, since it moves only when the *call* structure changes, not when
  a function body does.

  Writes `call_edge.facts` into `facts_dir`. Idempotent — re-running
  overwrites with the same content for the same inputs.
  """
  @spec derive_stage0(Path.t(), keyword()) :: :ok | {:error, term()}
  def derive_stage0(facts_dir, opts \\ []) do
    # Souffle writes outputs into -D; stage0.dl names them `.facts` so the
    # directory it lands in is directly reusable as a fact directory.
    case Souffle.run(facts_dir, stage0_rules_path(), Keyword.put(opts, :output_dir, facts_dir)) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, {:stage0, reason}}
    end
  end

  @doc """
  The path to the stage-0 rules file.
  """
  @spec stage0_rules_path() :: Path.t()
  def stage0_rules_path, do: priv_dl("stage0.dl")

  @doc """
  The relations an analysis actually reads, as Souffle resolves them.

  Derived from the transformed RAM program — the form that actually
  executes — rather than the source `.dl`. That distinction matters: the
  parsed AST lists every declared input including ones later pruned as
  unused, so reading the source over-approximates, and following
  `.include` by hand under-approximates (Souffle resolves includes
  relative to the including file). The RAM's `operation="input"` entries
  are the set Souffle will genuinely open.

  Incremental consumers use this to project a per-analysis fact directory,
  so an analysis only re-solves when a relation it truly reads has moved.

  Returns `{:ok, [relation_name]}` or `{:error, reason}`.
  """
  @spec input_relations(analysis()) :: {:ok, [String.t()]} | {:error, term()}
  def input_relations(analysis) do
    with {:ok, rules_path} <- resolve_rules(analysis) do
      Souffle.input_relations(rules_path)
    end
  end

  @doc """
  Runs a single analysis's Datalog rules against an existing facts directory.

  The facts directory must contain `.facts` files for every relation the
  analysis declares as input — `extract_facts/3` guarantees this when the
  analysis was included in its analyses list.

  Returns `{:ok, results}` or `{:error, reason}`.
  """
  @spec run_rules(Path.t(), analysis(), keyword()) :: {:ok, result()} | {:error, term()}
  def run_rules(facts_dir, analysis, opts \\ []) do
    with {:ok, rules_path} <- resolve_rules(analysis),
         :ok <- ensure_stage0(facts_dir, opts) do
      Souffle.run(facts_dir, rules_path, opts)
    end
  end

  # Analyses read the staged call graph, so it has to be there. Deriving
  # it only when absent keeps this a no-op on the hot path: extract_facts/3
  # already staged it, and incremental callers supply a directory that
  # carries their own memoized copy. Hand-built fact directories — tests,
  # ad-hoc probes — get it derived on demand rather than having to know
  # about staging at all.
  #
  # `stage0: :provided` opts out entirely. A caller that projects a fact
  # directory down to exactly the relations one analysis reads knows
  # whether call_edge is among them; for an analysis that does not read it
  # the file is legitimately absent, and auto-deriving would fail on the
  # layer-1 facts such a directory deliberately omits.
  defp ensure_stage0(facts_dir, opts) do
    cond do
      Keyword.get(opts, :stage0, :auto) == :provided ->
        :ok

      File.exists?(Path.join(facts_dir, "call_edge.facts")) and
        File.exists?(Path.join(facts_dir, "call_site.facts")) and
        File.exists?(Path.join(facts_dir, "unconditional_call_edge.facts")) and
          File.exists?(Path.join(facts_dir, "call_tag.facts")) ->
        :ok

      true ->
        derive_stage0(facts_dir, opts)
    end
  end

  @doc """
  Restricts raw Souffle results to the relations a built-in analysis
  declares as its outputs.

  Intermediate clientlib relations (`call_reachable`, `sync_dep`, ...) are
  dropped. Custom analyses and unknown names pass through unchanged — there
  is no declaration to filter against.
  """
  @spec filter_to_outputs(result(), analysis()) :: result()
  def filter_to_outputs(results, {:custom, _path}), do: results

  def filter_to_outputs(results, name) when is_atom(name) do
    case output_relations(name) do
      {:ok, relations} ->
        allowed = Enum.map(relations, &Atom.to_string(&1.name))
        Map.take(results, allowed)

      :error ->
        results
    end
  end

  # Imprecision tracking is off by default so every non-coverage analysis
  # pays only the cost of a single process-dict read per fallback site.
  # The coverage analysis is the only one that needs the extra data, so
  # we flip the flag here rather than asking callers to remember it.
  defp maybe_enable_imprecision_tracing(opts, analyses) do
    if :coverage in analyses do
      Keyword.put_new(opts, :trace_imprecision, true)
    else
      opts
    end
  end

  @doc """
  Returns the list of built-in analysis names.
  """
  @spec builtin_analyses() :: [atom()]
  def builtin_analyses do
    Enum.map(discover_analyses(), & &1.name())
  end

  @doc """
  Returns all discovered built-in analysis modules.
  """
  @spec builtin_analysis_modules() :: [module()]
  def builtin_analysis_modules do
    discover_analyses()
  end

  @doc """
  Looks up a built-in analysis module by name.

  Returns `{:ok, module}` or `:error` if not found.
  """
  @spec fetch_module(atom()) :: {:ok, module()} | :error
  def fetch_module(name) when is_atom(name) do
    case Enum.find(discover_analyses(), &(&1.name() == name)) do
      nil -> :error
      mod -> {:ok, mod}
    end
  end

  @doc """
  Returns output relations for a named built-in analysis.

  Returns `{:ok, relations}` or `:error` if the analysis is not found.
  """
  @spec output_relations(atom()) :: {:ok, [output_relation()]} | :error
  def output_relations(name) when is_atom(name) do
    case fetch_module(name) do
      {:ok, mod} -> {:ok, mod.output_relations()}
      :error -> :error
    end
  end

  # Discovery.

  defp discover_analyses do
    argus_modules()
    |> Enum.filter(fn mod ->
      Code.ensure_loaded?(mod) and
        function_exported?(mod, :name, 0) and
        function_exported?(mod, :rules_file, 0) and
        function_exported?(mod, :output_relations, 0)
    end)
    |> Enum.sort_by(& &1.name())
  end

  # The :modules key only exists once the application is *loaded* — which
  # plain code-path embedding (escripts, sandbox VMs that only call
  # :code.add_paths/1) never does. Loading is cheap, idempotent, and does
  # not start anything, so do it on demand rather than crash.
  defp argus_modules do
    case :application.get_key(:panoptes, :modules) do
      {:ok, modules} ->
        modules

      :undefined ->
        case :application.load(:panoptes) do
          ok when ok in [:ok, {:error, {:already_loaded, :panoptes}}] -> :ok
          {:error, reason} -> raise "could not load the :panoptes application: #{inspect(reason)}"
        end

        {:ok, modules} = :application.get_key(:panoptes, :modules)
        modules
    end
  end

  # Rules resolution.

  defp resolve_rules({:custom, path}) do
    if File.exists?(path) do
      {:ok, path}
    else
      {:error, {:rules_not_found, path}}
    end
  end

  defp resolve_rules(name) when is_atom(name) do
    case fetch_module(name) do
      {:ok, mod} ->
        path = priv_dl(mod.rules_file())

        if File.exists?(path) do
          {:ok, path}
        else
          {:error, {:rules_not_found, path}}
        end

      :error ->
        {:error, {:unknown_analysis, name}}
    end
  end

  # CallArgs is a universal extractor — it emits call_arg facts that
  # the interprocedural.dl rules use to derive additional sync_call /
  # async_cast rows. Including it for every analysis means the enriched
  # call graph is always available when Datalog rules consume it.
  @universal_extractors [Argus.Extractors.CallArgs]

  defp default_extractors_for({:custom, _}), do: @universal_extractors

  defp default_extractors_for(name) when is_atom(name) do
    case fetch_module(name) do
      {:ok, mod} -> @universal_extractors ++ mod.extractors()
      :error -> @universal_extractors
    end
  end

  defp priv_dl(filename) do
    Path.join(:code.priv_dir(:panoptes), "dl/#{filename}")
  end

  defp create_work_dir do
    case System.tmp_dir() do
      nil ->
        {:error, :no_tmp_dir}

      tmp ->
        # The OS pid distinguishes concurrently running VMs —
        # System.unique_integer/1 alone is VM-local, so two `elixir`
        # subprocesses started together pick the SAME integer and
        # silently clobber each other's facts mid-run (the cause of the
        # autoresearch corpus measurement variance).
        dir = Path.join(tmp, "argus_#{:os.getpid()}_#{System.unique_integer([:positive])}")

        # Remove any stale data from a dead VM that had the same OS pid
        # and picked the same integer, then create a fresh directory.
        File.rm_rf(dir)

        case File.mkdir_p(dir) do
          :ok -> {:ok, dir}
          {:error, reason} -> {:error, {:mkdir_failed, reason}}
        end
    end
  end
end
