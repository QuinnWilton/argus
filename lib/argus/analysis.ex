defmodule Argus.Analysis do
  @moduledoc """
  Behaviour and API for BEAM program analyses.

  Each analysis is a module that implements this behaviour, declaring its
  name, description, Souffle rules file, required extractors, and output
  relations. The system discovers these modules at runtime from the
  `:argus` application's module list.

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
          File.exists?(Path.join(facts_dir, "unconditional_call_edge.facts")) ->
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
    case :application.get_key(:argus, :modules) do
      {:ok, modules} ->
        modules

      :undefined ->
        case :application.load(:argus) do
          ok when ok in [:ok, {:error, {:already_loaded, :argus}}] -> :ok
          {:error, reason} -> raise "could not load the :argus application: #{inspect(reason)}"
        end

        {:ok, modules} = :application.get_key(:argus, :modules)
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
    Path.join(:code.priv_dir(:argus), "dl/#{filename}")
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
