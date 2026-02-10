defmodule Argus.Analysis do
  @moduledoc """
  High-level analysis API.

  Orchestrates the full pipeline: extract facts from modules, run Souffle
  rules, and return results as Elixir terms.

  ## Built-in analyses

  - `:cfg` — control flow graph edges
  - `:callgraph` — call graph edges
  - `:reachability` — transitive CFG and call reachability
  - `:reaching_def` — reaching definitions and def-use chains
  - `:liveness` — live variable analysis and dead definition detection
  - `:tail_call` — tail call identification and recursion detection
  - `:message_flow` — message send/receive pairing across functions
  - `:supervision` — supervision tree structure and anti-patterns
  - `:ets` — ETS table ownership, concurrency, and lifecycle analysis
  - `:coupled_siblings` — siblings under one_for_one with transitive coupling

  ## Custom analyses

  Pass `{:custom, "path/to/rules.dl"}` to run your own Datalog rules
  against the extracted facts.
  """

  alias Argus.Extract
  alias Argus.Souffle.CLI

  @type analysis ::
          :cfg
          | :callgraph
          | :reachability
          | :reaching_def
          | :liveness
          | :tail_call
          | :message_flow
          | :supervision
          | :ets
          | :coupled_siblings
          | {:custom, Path.t()}

  @type result :: %{String.t() => [[String.t()]]}

  @builtin_analyses %{
    cfg: "cfg.dl",
    callgraph: "callgraph.dl",
    reachability: "reachability.dl",
    supervision: "supervision.dl",
    reaching_def: "reaching_def.dl",
    liveness: "liveness.dl",
    tail_call: "tail_call.dl",
    message_flow: "message_flow.dl",
    ets: "ets.dl",
    coupled_siblings: "coupled_siblings.dl"
  }

  @analysis_extractors %{
    supervision: [Argus.Extractors.Supervision, Argus.Extractors.OTP],
    ets: [Argus.Extractors.ETS, Argus.Extractors.OTP],
    coupled_siblings: [Argus.Extractors.Supervision, Argus.Extractors.OTP]
  }

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
    default_extractors = Map.get(@analysis_extractors, analysis, [])
    opts = Keyword.update(opts, :extractors, default_extractors, &(default_extractors ++ &1))

    with {:ok, rules_path} <- resolve_rules(analysis),
         {:ok, work_dir} <- create_work_dir(),
         facts_dir = Path.join(work_dir, "facts"),
         {:ok, _} <- Extract.run(modules, facts_dir, opts),
         {:ok, results} <- CLI.run(facts_dir, rules_path, opts) do
      {:ok, results}
    end
  end

  @doc """
  Returns the list of built-in analysis names.
  """
  @spec builtin_analyses() :: [atom()]
  def builtin_analyses, do: Map.keys(@builtin_analyses)

  defp resolve_rules({:custom, path}) do
    if File.exists?(path) do
      {:ok, path}
    else
      {:error, {:rules_not_found, path}}
    end
  end

  defp resolve_rules(name) when is_atom(name) do
    case Map.fetch(@builtin_analyses, name) do
      {:ok, filename} ->
        path = priv_dl(filename)

        if File.exists?(path) do
          {:ok, path}
        else
          {:error, {:rules_not_found, path}}
        end

      :error ->
        {:error, {:unknown_analysis, name}}
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

        case File.mkdir_p(dir) do
          :ok -> {:ok, dir}
          {:error, reason} -> {:error, {:mkdir_failed, reason}}
        end
    end
  end
end
