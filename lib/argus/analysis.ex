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
          name: atom(),
          fields: [Argus.Schema.field()],
          doc: String.t()
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
      Souffle.run(facts_dir, rules_path, opts)
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
      |> maybe_enable_imprecision_tracing(analyses)

    with {:ok, work_dir} <- create_work_dir(),
         facts_dir = Path.join(work_dir, "facts"),
         {:ok, _} <- Pipeline.run(modules, facts_dir, opts) do
      {:ok, facts_dir}
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
    with {:ok, rules_path} <- resolve_rules(analysis) do
      Souffle.run(facts_dir, rules_path, opts)
    end
  end

  @doc """
  Restricts raw Souffle results to the relations a built-in analysis
  declares as its outputs.

  Intermediate clientlib relations (`call_reachable`, `cfg_edge`, ...) and
  bookkeeping keys (`_argus_mode`) are dropped. Custom analyses and unknown
  names pass through unchanged — there is no declaration to filter against.
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
    {:ok, modules} = :application.get_key(:argus, :modules)

    modules
    |> Enum.filter(fn mod ->
      Code.ensure_loaded?(mod) and
        function_exported?(mod, :name, 0) and
        function_exported?(mod, :rules_file, 0) and
        function_exported?(mod, :output_relations, 0)
    end)
    |> Enum.sort_by(& &1.name())
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
        dir = Path.join(tmp, "argus_#{System.unique_integer([:positive])}")

        # Remove any stale data from a previous VM that picked the
        # same integer, then create a fresh directory.
        File.rm_rf(dir)

        case File.mkdir_p(dir) do
          :ok -> {:ok, dir}
          {:error, reason} -> {:error, {:mkdir_failed, reason}}
        end
    end
  end
end
