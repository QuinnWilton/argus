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
    asks. A program whose exact fixpoint outgrows the stage's budget
    runs it bounded instead (`priv/dl/points_to_bounded.dl`, see
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

  # The relations stage 0 writes; a directory holding every one is staged.
  @stage0_relations ~w(call_edge call_site unconditional_call_edge call_tag fun_handed_to)

  # The relations the points-to stage writes (points_to.dl's outputs):
  # what the analyses read, and which stage wrote them.
  @points_to_relations ~w(server_process instance supervised_process private_process process
                          named_pid process_call process_signal call_site_target self_call
                          source_process source_table points_to_mode)

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
  # fixpoint outgrows its budget (`derive_points_to/2`): the facts with
  # its outputs, or `{:error, {:points_to, reason}}`, the facts still the
  # caller's (the analyses that do not read the stage can run on them).
  # Each solve is kept, the exact one that outgrew the budget too: a
  # warm run reads both back and runs neither.
  @spec solve_points_to(Facts.t(), keyword()) :: {:ok, Facts.t()} | {:error, term()}
  def solve_points_to(facts, opts) do
    solve = fn rules_path, facts -> Facts.solve(facts, rules_path, opts) end

    case stage_points_to(solve, facts) do
      {:ok, solved} ->
        {:ok, solved}

      {:error, reason, solved} ->
        # A directory a solve made for itself goes with the failure.
        if solved.work != facts.work, do: Facts.release(solved)
        points_to_failed(reason)
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
  # fixpoint outgrows its budget.
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

  Writes the `stage0_relations/0` files into `facts_dir`, none when it
  fails. The solver writes them into a directory of its own, and each
  is renamed into place whole, so a reader of `facts_dir` never sees one
  being written. Idempotent, and safe beside another derivation into
  the same directory: re-running replaces each file with the same
  content for the same inputs.
  """
  @spec derive_stage0(Path.t(), keyword()) :: :ok | {:error, term()}
  def derive_stage0(facts_dir, opts \\ []) do
    # stage0.dl names its outputs `.facts`, so the directory they land in
    # is directly reusable as a fact directory.
    result =
      with {:ok, _results, aside} <- solve_aside(facts_dir, stage0_rules_path(), opts) do
        try do
          publish(aside, facts_dir, @stage0_relations)
        after
          File.rm_rf(aside)
        end
      end

    case result do
      :ok -> :ok
      {:error, reason} -> {:error, {:stage0, reason}}
    end
  end

  # A stage solved over `facts_dir` into a directory of its own inside
  # it, never into `facts_dir` itself: `{:ok, results, aside}`, the
  # outputs in `aside` for `publish/3`, or the solve's error (`aside`
  # gone). Inside, so a rename moves each output into place: the same
  # volume, whoever made the directory.
  defp solve_aside(facts_dir, rules_path, opts) do
    aside = Path.join(facts_dir, ".stage-#{:os.getpid()}-#{System.unique_integer([:positive])}")

    case File.mkdir(aside) do
      :ok ->
        case Souffle.run(facts_dir, rules_path, Keyword.put(opts, :output_dir, aside)) do
          {:ok, results} ->
            {:ok, results, aside}

          {:error, _} = error ->
            File.rm_rf(aside)
            error
        end

      {:error, reason} ->
        {:error, {:mkdir_failed, aside, reason}}
    end
  end

  # Each `.facts` file a stage wrote into `aside`, renamed into
  # `facts_dir` over what is there: `required` names the relations it
  # must have written. A reader of `facts_dir` sees each file whole, the
  # old one or the new, never one being written.
  #
  # Never solved in place: a directory can have several readers and
  # writers at once. scry names its fact directories by their content,
  # so every solve over the same facts derives the same stage into the
  # same one. Souffle opens an output truncated and writes it where it
  # stands, so a reader there would see a file cut short; and a stage's
  # reports, read back and removed from there, would be removed from
  # under another derivation that has written them and not yet read
  # them (`{:missing_output, "points_to_overflow"}`).
  defp publish(aside, facts_dir, required) do
    with {:ok, names} <- File.ls(aside) do
      written = names |> Enum.filter(&String.ends_with?(&1, ".facts")) |> Enum.sort()

      case Enum.reject(required, &("#{&1}.facts" in written)) do
        [] -> rename_each(written, aside, facts_dir)
        [missing | _] -> {:error, {:missing_output, missing}}
      end
    end
  end

  defp rename_each(names, from, to) do
    Enum.reduce_while(names, :ok, fn name, :ok ->
      case File.rename(Path.join(from, name), Path.join(to, name)) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:publish_failed, name, reason}}}
      end
    end)
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

  The stage is exact within a budget: `points_to_rules_path/0` holds its
  fixpoint to 500,000 rows of what a source may point to and of what a
  term's field may hold, where the largest of twenty programs it was
  measured on holds 45,000. A program whose helpers merge most of its
  terms into one value grows past that with the square of those terms
  (Ash: 13 million rows after thirteen minutes) and runs bounded
  instead (`points_to_bounded_rules_path/0`): the leaves a coarse pass
  finds pervasive (held by more than one source in a hundred) are
  resolved by that pass, a superset of their exact rows, and every
  other one exactly. Souffle stops a fixpoint at the budget however
  fast it runs, so which stage runs is a function of the facts: the
  same facts run the same stage on any machine, under any load, afresh
  or from a store. `points_to_mode.facts` says which one wrote the
  relations, and a warning names the leaves a bounded stage resolved
  coarsely. Ash outgrows the budget in six seconds and runs bounded in
  ten.

  A stage that outgrows the budget even bounded, or does not finish
  within `:souffle_timeout`, fails with a warning, `{:error,
  {:points_to, reason}}`, and the analyses that read it degrade
  (`Argus.Findings.run/2`): time can fail the stage, never change what
  it answers.

  Writes the `points_to_relations/0` files into `facts_dir`, each renamed
  into place whole (as stage 0's, `derive_stage0/2`), and none when it
  fails: a failure leaves the directory as it found it. What the stage
  reports (its overflow, its pervasive leaves) is read back, never left
  among the facts. Idempotent, and safe beside another derivation into
  the same directory.
  """
  @spec derive_points_to(Path.t(), keyword()) :: :ok | {:error, term()}
  def derive_points_to(facts_dir, opts \\ []) do
    # Each solve over `facts_dir` into a directory of its own; the last
    # one's outputs are the stage's, any before it (an exact stage that
    # outgrew its budget: what it had reached, none of it an answer)
    # are discarded with it.
    solve = fn rules_path, {dir, asides} ->
      with {:ok, results, aside} <- solve_aside(dir, rules_path, opts),
           do: {:ok, results, {dir, [aside | asides]}}
    end

    {result, asides} =
      case stage_points_to(solve, {facts_dir, []}) do
        {:ok, {_dir, [aside | _] = asides}} ->
          {publish(aside, facts_dir, @points_to_relations), asides}

        {:error, reason, {_dir, asides}} ->
          {{:error, reason}, asides}
      end

    Enum.each(asides, &File.rm_rf/1)

    case result do
      :ok -> :ok
      {:error, reason} -> points_to_failed(reason)
    end
  end

  # The points-to stage: the exact program, and the bounded one when the
  # exact fixpoint outgrows its budget. `solve` takes a rules path and
  # what the previous solve returned (the facts it solves over:
  # `Argus.Cache.Facts`, or a directory and the solves' own output
  # directories), and returns what `Argus.Cache.Facts.solve/3` does.
  # The answer is `{:ok, solved}` or `{:error, reason, solved}`,
  # `solved` what the last solve returned, for the caller to clean up
  # after.
  defp stage_points_to(solve, facts) do
    case solve.(points_to_rules_path(), facts) do
      {:ok, results, solved} ->
        case overflow(results) do
          {:ok, []} -> {:ok, solved}
          {:ok, exact_over} -> bounded_points_to(solve, solved, exact_over)
          {:error, reason} -> {:error, reason, solved}
        end

      {:error, reason} ->
        {:error, reason, facts}
    end
  end

  # The bounded stage over the facts the exact one was solved over: it
  # writes every relation the exact one does, so each partial one is
  # replaced.
  defp bounded_points_to(solve, facts, exact_over) do
    case solve.(points_to_bounded_rules_path(), facts) do
      {:ok, results, solved} ->
        case overflow(results) do
          {:ok, []} ->
            report_bounded(exact_over, results)
            {:ok, solved}

          {:ok, over} ->
            {:error, {:over_budget, over}, solved}

          {:error, reason} ->
            {:error, reason, solved}
        end

      {:error, reason} ->
        {:error, reason, facts}
    end
  end

  # The relations that reached the stage's budget, `{relation, rows,
  # budget}`: none when the fixpoint is complete. Every stage writes the
  # file, so a solve without it is not one of the stage's.
  defp overflow(results) do
    case Map.fetch(results, "points_to_overflow") do
      {:ok, rows} ->
        {:ok,
         for [relation, count, budget] <- rows do
           {relation, String.to_integer(count), String.to_integer(budget)}
         end}

      :error ->
        {:error, {:missing_output, "points_to_overflow"}}
    end
  end

  defp report_bounded(exact_over, results) do
    leaves = results |> Map.get("pervasive", []) |> List.flatten() |> Enum.sort()

    Logger.warning(
      "points-to: the exact stage outgrew its budget (#{budget_summary(exact_over)}); " <>
        "ran it bounded, " <> pervasive_summary(leaves)
    )
  end

  # A failed stage degrades every analysis that reads it: said once
  # here, whichever caller runs it.
  defp points_to_failed(reason) do
    Logger.warning(
      "points-to: " <> failure_summary(reason) <> "; the analyses reading it degrade"
    )

    {:error, {:points_to, reason}}
  end

  defp failure_summary({:over_budget, over}),
    do: "the stage outgrew its budget even bounded (#{budget_summary(over)})"

  defp failure_summary(:souffle_timeout),
    do: "the stage did not finish within :souffle_timeout"

  defp failure_summary(reason), do: "the stage failed: #{inspect(reason)}"

  defp budget_summary(over) do
    Enum.map_join(over, ", ", fn {relation, rows, budget} ->
      "#{relation} reached #{rows} rows, over #{budget}"
    end)
  end

  defp pervasive_summary([]), do: "which found no leaf pervasive"

  defp pervasive_summary(leaves) do
    shown = Enum.take(leaves, 3)
    more = if length(leaves) > length(shown), do: ", …", else: ""

    "resolving #{length(leaves)} pervasive leaves coarsely (#{Enum.join(shown, ", ")}#{more})"
  end

  @doc "The path to the points-to stage's rules file."
  @spec points_to_rules_path() :: Path.t()
  def points_to_rules_path, do: Catalog.priv_dl("points_to.dl")

  @doc """
  The path to the bounded points-to stage's rules file: what
  `derive_points_to/2` runs when the exact stage outgrows its budget. A
  consumer that keys the stage on its programs keys it on this one too.
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
