defmodule Argus.Analysis.Extraction do
  @moduledoc """
  Turns modules into a facts directory the analyses' rules can read.

  One extraction serves every selected analysis: the pipeline
  (`Argus.Pipeline.run/3`) runs the union of the analyses' extractors
  once, then three derivations write into the same directory:

  - **Stage 0** (`priv/dl/stage0.dl`) derives the shared call graph
    (`call_edge`, `call_site`, `unconditional_call_edge`, `call_tag`,
    `fun_handed_to`)
    once, so no analysis re-derives it and the volatile
    instruction-level relations stay out of every analysis's input set.
  - **Points-to** (`priv/dl/points_to.dl`), when a selected analysis
    reads it, derives which process a pid can be
    (`points_to_relations/0`) once: the fixpoint is most of a solve
    over a large program, and it is the same for every analysis that
    asks. When it does not finish within `:points_to_timeout`, the stage
    runs bounded instead (`priv/dl/points_to_bounded.dl`, see
    `derive_points_to/2`).
  - **Priors** (`Argus.Priors`), only when `:priors` asks for them, fill
    the `prior_*` relations the heuristic rules read.

  A module an extractor fails on is not a failed extraction: the
  pipeline records it as an `extraction_error` row and goes on, and
  `Argus.Findings.extraction_errors/1` reads the rows back.

  `Argus.Analysis` delegates `extract_facts/3`, `derive_stage0/2`,
  `derive_points_to/2`, their rules paths and relation lists here.
  """

  require Logger

  alias Argus.Analysis
  alias Argus.Analysis.Catalog
  alias Argus.Cache.Facts
  alias Argus.Pipeline
  alias Argus.Souffle

  # CallArgs is a universal extractor — it emits call_arg facts that
  # clientlib/calls.dl's resolved_arg uses to resolve sync_call /
  # async_cast targets. Including it for every analysis means the enriched
  # call graph is always available when Datalog rules consume it.
  @universal_extractors [Argus.Extractors.CallArgs]

  # The relations stage 0 writes; a directory holding all four is staged.
  @stage0_relations ~w(call_edge call_site unconditional_call_edge call_tag fun_handed_to)

  # How long the exact points-to stage gets, in milliseconds, before the
  # stage runs bounded instead. The exact stage takes a second or two on
  # the largest programs it was measured on (a 1,239-module umbrella, a
  # 751-module deps tree); the programs it does not finish on take ten
  # minutes and more (Ash, 1,327 modules: 13 minutes), where the bounded
  # stage takes ten seconds.
  @points_to_timeout 15_000

  # The relations the points-to stage writes (points_to.dl's outputs).
  @points_to_relations ~w(server_process instance supervised_process private_process process
                          named_pid process_call process_signal call_site_target self_call
                          source_process source_table)

  @doc """
  Extracts facts from the given modules once, for one or more analyses.

  Runs the pipeline with the union of the analyses' default extractors
  (plus any extra `:extractors` from `opts`), writing `.facts` files to a
  fresh temporary directory. Because the pipeline always materializes
  every schema relation (empty files included), the resulting directory
  can feed `Argus.Analysis.run_rules/3` for each of the analyses without
  re-extraction.

  Returns `{:ok, facts_dir}` or `{:error, reason}`; a stage-0 failure is
  `{:error, {:stage0, reason}}`, a points-to one `{:error, {:points_to,
  reason}}`.

  `points_to: :deferred` leaves the points-to stage to the caller, who
  stages it with `ensure_points_to/3` and decides what its failure means
  (`Argus.Findings.run/2` degrades only the analyses that read it).

  `cache:` names a store (`Argus.Cache`): each producer's facts are read
  from it or extracted and kept there (`Argus.Cache.Facts`), stage 0 and
  the points-to stage are solved through it, and the directory returned
  is hard links into it, byte-identical to one extracted afresh — its
  links are read-only, and the caller removes it as any other. Priors
  are derived into it every time, as without a store. Ignored under
  `ARGUS_NO_CACHE`.
  """
  @spec extract_facts(modules :: [atom() | String.t()], [Analysis.analysis()], keyword()) ::
          {:ok, Path.t()} | {:error, term()}
  def extract_facts(modules, analyses, opts \\ []) do
    opts = pipeline_opts(analyses, opts)
    Argus.Priors.check!(opts)

    case cached(modules, analyses, opts) do
      {:ok, facts} ->
        case Facts.materialize(facts) do
          {:ok, facts} ->
            {:ok, facts.dir}

          {:error, _} = error ->
            Facts.release(facts)
            error
        end

      :uncached ->
        extract_afresh(modules, analyses, opts)

      {:error, _} = error ->
        error
    end
  end

  defp extract_afresh(modules, analyses, opts) do
    with {:ok, work_dir} <- create_work_dir(),
         facts_dir = Path.join(work_dir, "facts"),
         {:ok, _} <- Pipeline.run(modules, facts_dir, opts),
         :ok <- derive_stage0(facts_dir, opts),
         :ok <- points_to_unless_deferred(facts_dir, analyses, opts),
         :ok <- derive_priors(facts_dir, opts) do
      {:ok, facts_dir}
    end
  end

  # What the pipeline runs with for these analyses: their extractors
  # (and any the caller adds), the relations they may read, and
  # imprecision tracing for coverage.
  defp pipeline_opts(analyses, opts) do
    default_extractors =
      analyses
      |> Enum.flat_map(&default_extractors_for/1)
      |> Enum.uniq()

    opts
    |> Keyword.update(:extractors, default_extractors, &Enum.uniq(default_extractors ++ &1))
    |> Keyword.put_new(:relations, staged_relations(analyses))
    |> maybe_enable_imprecision_tracing(analyses)
  end

  @doc false
  # The facts `extract_facts/3` would extract, through the store `cache:`
  # names (`Argus.Cache.Facts`), with stage 0 solved into them and the
  # points-to stage unless `points_to: :deferred`: `{:ok, facts}` for
  # the caller to release, `:uncached` when there is no store to use
  # (none named, stores off, or a producer whose code no key can name),
  # or the error extraction would return.
  @spec cached_facts([atom() | String.t()], [Analysis.analysis()], keyword()) ::
          {:ok, Facts.t()} | :uncached | {:error, term()}
  def cached_facts(modules, analyses, opts) do
    cached(modules, analyses, pipeline_opts(analyses, opts))
  end

  defp cached(modules, analyses, opts) do
    with store when is_binary(store) <- Argus.Cache.store(opts) || :uncached,
         {:ok, facts} <- shards(modules, opts, store),
         {:ok, facts} <- solve_stage(facts, stage0_rules_path(), :stage0, opts),
         {:ok, facts} <- cached_points_to(facts, analyses, opts) do
      cached_priors(facts, opts)
    end
  end

  defp cached_points_to(facts, analyses, opts) do
    programs = [programs: Argus.Cache.dir(facts.store, :programs)]

    if Keyword.get(opts, :points_to, :derive) == :derive and
         Enum.any?(analyses, &reads_points_to?(&1, programs)) do
      with {:error, _} = error <- solve_points_to(facts, opts) do
        Facts.release(facts)
        error
      end
    else
      {:ok, facts}
    end
  end

  @doc false
  # The points-to stage solved into cached facts, bounded when the exact
  # stage does not finish in time (`derive_points_to/2`): the facts with
  # its outputs, or `{:error, {:points_to, reason}}`, the facts still the
  # caller's (the analyses that do not read the stage can run on them).
  @spec solve_points_to(Facts.t(), keyword()) :: {:ok, Facts.t()} | {:error, term()}
  def solve_points_to(facts, opts) do
    solve = fn rules_path, opts -> Facts.solve(facts, rules_path, opts) end

    case bounded_on_timeout(solve, opts) do
      {:ok, _results, facts} -> {:ok, facts}
      {:error, reason} -> {:error, {:points_to, reason}}
    end
  end

  # Priors are asked afresh every run, as without a store: into a
  # directory of the facts, whose `prior_*` files then join the facts by
  # their content, so the solves reading them are keyed on what the
  # model said.
  defp cached_priors(facts, opts) do
    if Keyword.get(opts, :priors, :off) == :off do
      {:ok, facts}
    else
      with {:ok, facts} <- Facts.materialize(facts),
           :ok <- derive_priors(facts.dir, opts) do
        Facts.refresh(facts, Enum.map(Argus.Schema.layer_3(), &"#{&1.name}.facts"))
      end
    end
  end

  defp shards(modules, opts, store) do
    shard_opts = Keyword.take(opts, [:relations, :trace_imprecision, :concurrency, :timeout])

    case Facts.extract(modules, Keyword.fetch!(opts, :extractors), shard_opts, store) do
      {:error, {:uncacheable, _}} -> :uncached
      other -> other
    end
  end

  @doc false
  # A stage solved into cached facts: the facts with its outputs, or
  # `{:error, {stage, reason}}` (the facts released). The points-to stage
  # goes through solve_points_to/2, which runs it bounded when the exact
  # stage runs out of time.
  @spec solve_stage(Facts.t(), Path.t(), :stage0, keyword()) ::
          {:ok, Facts.t()} | {:error, term()}
  def solve_stage(facts, rules_path, stage, opts) do
    case Facts.solve(facts, rules_path, opts) do
      {:ok, _results, facts} ->
        {:ok, facts}

      {:error, reason} ->
        Facts.release(facts)
        {:error, {stage, reason}}
    end
  end

  defp points_to_unless_deferred(facts_dir, analyses, opts) do
    case Keyword.get(opts, :points_to, :derive) do
      :deferred -> :ok
      :derive -> ensure_points_to(facts_dir, analyses, opts)
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
  # everything. Named as what is left out, not what is kept: the option
  # keys every shard (`Argus.Cache.Facts`), and a relation added to the
  # schema moves no key.
  defp staged_relations(analyses) do
    if Enum.any?(analyses, &match?({:custom, _}, &1)) do
      :all
    else
      {:except, Argus.Schema.in_process_only()}
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

  @doc "The relations stage 0 writes."
  @spec stage0_relations() :: [String.t()]
  def stage0_relations, do: @stage0_relations

  @doc """
  Derives the points-to stage into an existing facts directory that
  stage 0 has been derived into.

  Process points-to (`clientlib/processes.dl`) is a whole-program
  fixpoint, and every analysis that asks which process a pid can be
  used to derive it inside its own solve: over a large program, most of
  the solve, and the same rows each time. This derives them once, and
  the analyses read `points_to_relations/0` as facts
  (`clientlib/staged_processes.dl`).

  Like stage 0, an incremental consumer calls it directly and memoizes
  the result: its outputs move only when a process or a resolved target
  does, not on every edit that renumbers the instructions it reads.

  The stage is exact unless it does not finish within
  `:points_to_timeout` (milliseconds, 15 seconds by default; `:infinity`
  keeps it exact whatever it takes, within `:souffle_timeout`). It then
  runs bounded (`points_to_bounded_rules_path/0`): the leaves a coarse
  pass finds pervasive — held by more than one source in a hundred —
  are resolved by that pass, and every other one exactly. The bounded
  stage writes the same relations, a superset of the exact stage's rows
  for the pervasive leaves; a warning names how many it bounded. On
  every program it was measured on but one the exact stage finishes in
  a second or two; the exception (Ash, where helpers that return an
  updated copy of their parameter merge most of the heap) takes ten
  seconds bounded and thirteen minutes exact.

  Writes the `points_to_relations/0` files into `facts_dir`. Idempotent.
  """
  @spec derive_points_to(Path.t(), keyword()) :: :ok | {:error, term()}
  def derive_points_to(facts_dir, opts \\ []) do
    solve = fn rules_path, opts ->
      Souffle.run(facts_dir, rules_path, Keyword.put(opts, :output_dir, facts_dir))
    end

    case bounded_on_timeout(solve, opts) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, {:points_to, reason}}
    end
  end

  # Solves the exact stage within the points-to budget, and the bounded
  # one when it runs out: `solve` takes a rules path and options and
  # returns what `Argus.Souffle.run/3` or `Argus.Cache.Facts.solve/3`
  # does.
  defp bounded_on_timeout(solve, opts) do
    case Keyword.get(opts, :points_to_timeout, @points_to_timeout) do
      :infinity ->
        solve.(points_to_rules_path(), opts)

      budget ->
        exact = Keyword.update(opts, :souffle_timeout, budget, &min(&1, budget))

        case solve.(points_to_rules_path(), exact) do
          {:error, :souffle_timeout} ->
            solve.(points_to_bounded_rules_path(), opts) |> report_bounded(budget)

          other ->
            other
        end
    end
  end

  defp report_bounded(result, budget) do
    with {:ok, results} <- results(result) do
      leaves = results |> Map.get("pervasive", []) |> List.flatten() |> Enum.sort()

      Logger.warning(
        "points-to: the exact stage did not finish in #{budget} ms; ran it bounded, " <>
          pervasive_summary(leaves)
      )
    end

    result
  end

  defp pervasive_summary([]), do: "which found no leaf pervasive"

  defp pervasive_summary(leaves) do
    shown = Enum.take(leaves, 3)
    more = if length(leaves) > length(shown), do: ", …", else: ""

    "resolving #{length(leaves)} pervasive leaves coarsely (#{Enum.join(shown, ", ")}#{more})"
  end

  defp results({:ok, results}), do: {:ok, results}
  defp results({:ok, results, _facts}), do: {:ok, results}
  defp results(_error), do: :error

  @doc "The path to the points-to stage's rules file."
  @spec points_to_rules_path() :: Path.t()
  def points_to_rules_path, do: Catalog.priv_dl("points_to.dl")

  @doc """
  The path to the bounded points-to stage's rules file: what
  `derive_points_to/2` runs when the exact stage does not finish in time.
  """
  @spec points_to_bounded_rules_path() :: Path.t()
  def points_to_bounded_rules_path, do: Catalog.priv_dl("points_to_bounded.dl")

  @doc "The relations the points-to stage writes."
  @spec points_to_relations() :: [String.t()]
  def points_to_relations, do: @points_to_relations

  @doc """
  Whether an analysis reads what the points-to stage writes, as Souffle
  resolves its inputs (`programs:` as `Argus.Analysis.input_relations/2`
  takes it). An analysis whose inputs cannot be resolved is taken to
  read it: deriving the stage then reports the real trouble.
  """
  @spec reads_points_to?(Analysis.analysis(), keyword()) :: boolean()
  def reads_points_to?(analysis, opts \\ []) do
    case Analysis.input_relations(analysis, opts) do
      {:ok, relations} -> Enum.any?(relations, &(&1 in @points_to_relations))
      {:error, _} -> true
    end
  end

  @doc """
  Derives the points-to stage into `facts_dir` when one of `analyses`
  reads it and it is not already there.

  `stage0: :provided` in `opts` opts out, as it does for stage 0: a
  caller that projects a directory per analysis supplies the staged
  relations the analysis reads itself.
  """
  @spec ensure_points_to(Path.t(), [Analysis.analysis()], keyword()) :: :ok | {:error, term()}
  def ensure_points_to(facts_dir, analyses, opts) do
    cond do
      Keyword.get(opts, :stage0, :auto) == :provided ->
        :ok

      Enum.all?(@points_to_relations, &File.exists?(Path.join(facts_dir, "#{&1}.facts"))) ->
        :ok

      not Enum.any?(analyses, &reads_points_to?/1) ->
        :ok

      true ->
        derive_points_to(facts_dir, opts)
    end
  end

  @doc """
  Derives stage 0 into `facts_dir` unless it is already there.

  Analyses read the staged call graph, so it has to be there. Deriving it
  only when absent keeps this a no-op on the hot path: `extract_facts/3`
  already staged it, and incremental callers supply a directory that
  carries their own memoized copy. Hand-built fact directories — tests,
  ad-hoc probes — get it derived on demand rather than having to know
  about staging at all.

  `stage0: :provided` in `opts` opts out entirely, of this stage and of
  the points-to one (`ensure_points_to/3`). A caller that projects a
  fact directory down to exactly the relations one analysis reads knows
  whether call_edge is among them; for an analysis that does not read it
  the file is legitimately absent, and auto-deriving would fail on the
  layer-1 facts such a directory deliberately omits.
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
