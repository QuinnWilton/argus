defmodule Argus.Analysis.Extraction do
  @moduledoc """
  Turns modules into a facts directory the analyses' rules can read.

  One extraction serves every selected analysis: the pipeline
  (`Argus.Pipeline.run/3`) runs the union of the analyses' extractors
  once, then two derivations write into the same directory:

  - **Stage 0** (`priv/dl/stage0.dl`) derives the shared call graph
    (`call_edge`, `call_site`, `unconditional_call_edge`, `call_tag`)
    once, so no analysis re-derives it and the volatile
    instruction-level relations stay out of every analysis's input set.
  - **Priors** (`Argus.Priors`), only when `:priors` asks for them, fill
    the `prior_*` relations the heuristic rules read.

  A module an extractor fails on is not a failed extraction: the
  pipeline records it as an `extraction_error` row and goes on, and
  `Argus.Findings.extraction_errors/1` reads the rows back.

  `Argus.Analysis` delegates `extract_facts/3`, `derive_stage0/2` and
  `stage0_rules_path/0` here.
  """

  require Logger

  alias Argus.Analysis
  alias Argus.Analysis.Catalog
  alias Argus.Pipeline
  alias Argus.Souffle

  # CallArgs is a universal extractor — it emits call_arg facts that
  # clientlib/calls.dl's resolved_arg uses to resolve sync_call /
  # async_cast targets. Including it for every analysis means the enriched
  # call graph is always available when Datalog rules consume it.
  @universal_extractors [Argus.Extractors.CallArgs]

  # The relations stage 0 writes; a directory holding all four is staged.
  @stage0_relations ~w(call_edge call_site unconditional_call_edge call_tag)

  @doc """
  Extracts facts from the given modules once, for one or more analyses.

  Runs the pipeline with the union of the analyses' default extractors
  (plus any extra `:extractors` from `opts`), writing `.facts` files to a
  fresh temporary directory. Because the pipeline always materializes
  every schema relation (empty files included), the resulting directory
  can feed `Argus.Analysis.run_rules/3` for each of the analyses without
  re-extraction.

  Returns `{:ok, facts_dir}` or `{:error, reason}`; a stage-0 failure is
  `{:error, {:stage0, reason}}`.
  """
  @spec extract_facts(modules :: [atom() | String.t()], [Analysis.analysis()], keyword()) ::
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

    Argus.Priors.check!(opts)

    with {:ok, work_dir} <- create_work_dir(),
         facts_dir = Path.join(work_dir, "facts"),
         {:ok, _} <- Pipeline.run(modules, facts_dir, opts),
         :ok <- derive_stage0(facts_dir, opts),
         :ok <- derive_priors(facts_dir, opts) do
      {:ok, facts_dir}
    end
  end

  # Priors after stage 0, into the same directory: the empty `prior_*`
  # files the pipeline touched become the classifier's rows. A prior that
  # cannot be derived is logged and left empty — the findings are then
  # those of a run without priors, which is always a valid result.
  defp derive_priors(facts_dir, opts) do
    case Keyword.get(opts, :priors, :off) do
      :off ->
        :ok

      mode ->
        priors_opts = opts |> Keyword.get(:priors_opts, []) |> Keyword.put(:mode, mode)

        case Argus.Priors.derive(facts_dir, priors_opts) do
          {:ok, _stats} ->
            :ok

          {:error, reason} ->
            Logger.warning("priors not derived, relations left empty: #{inspect(reason)}")
            :ok
        end
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

  @doc "The path to the stage-0 rules file."
  @spec stage0_rules_path() :: Path.t()
  def stage0_rules_path, do: Catalog.priv_dl("stage0.dl")

  @doc """
  Derives stage 0 into `facts_dir` unless it is already there.

  Analyses read the staged call graph, so it has to be there. Deriving it
  only when absent keeps this a no-op on the hot path: `extract_facts/3`
  already staged it, and incremental callers supply a directory that
  carries their own memoized copy. Hand-built fact directories — tests,
  ad-hoc probes — get it derived on demand rather than having to know
  about staging at all.

  `stage0: :provided` in `opts` opts out entirely. A caller that projects
  a fact directory down to exactly the relations one analysis reads
  knows whether call_edge is among them; for an analysis that does not
  read it the file is legitimately absent, and auto-deriving would fail
  on the layer-1 facts such a directory deliberately omits.
  """
  @spec ensure_stage0(Path.t(), keyword()) :: :ok | {:error, term()}
  def ensure_stage0(facts_dir, opts) do
    cond do
      Keyword.get(opts, :stage0, :auto) == :provided ->
        :ok

      Enum.all?(@stage0_relations, &File.exists?(Path.join(facts_dir, "#{&1}.facts"))) ->
        :ok

      true ->
        derive_stage0(facts_dir, opts)
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

  defp default_extractors_for({:custom, _}), do: @universal_extractors

  defp default_extractors_for(name) when is_atom(name) do
    case Catalog.fetch(name) do
      {:ok, mod} -> @universal_extractors ++ mod.extractors()
      :error -> @universal_extractors
    end
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
