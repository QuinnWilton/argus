defmodule Scry.Runner do
  @moduledoc """
  The shared driver core for `mix compile.scry` and `mix scry`: database
  lifecycle, manifest warm start, input sync, the souffle gate, and
  analysis demand.

  One `Roux.Database` lives for the duration of a run; the manifest is
  the only continuity across OS processes. The manifest is written even
  when analyses degrade — the input syncs done this run stay warm, so
  error-loop editing stays incremental.

  When souffle is missing, no solve is demanded at all: a memoized
  `{:error, :souffle_not_found}` would only heal when an input above it
  changed, so the degraded path never lets one into the manifest. The
  souffle version rides every `:rules_digest` (`Scry.Fingerprint`), so
  upgrading the solver re-solves without re-extracting.
  """

  alias Roux.Database
  alias Roux.Input
  alias Roux.Lang.Manifest
  alias Roux.Memo

  defmodule Result do
    @moduledoc "The outcome of one driver run."

    @enforce_keys [
      :findings_by_file,
      :degraded,
      :extraction_errors,
      :duplicates,
      :souffle_missing?,
      :changed?
    ]
    defstruct [
      :findings_by_file,
      :degraded,
      :extraction_errors,
      :duplicates,
      :souffle_missing?,
      :changed?
    ]

    @type t :: %__MODULE__{
            findings_by_file: %{optional(String.t()) => [map()]},
            degraded: [%{analysis: atom(), reason: term()}],
            extraction_errors: [
              %{module: module() | nil, name: String.t(), step: String.t(), reason: String.t()}
            ],
            duplicates: [Scry.Scanner.duplicate()],
            souffle_missing?: boolean(),
            changed?: boolean()
          }
  end

  @doc """
  The manifest path shared by `mix compile.scry` and `mix scry` — one
  incremental state, whichever entry point drives it.
  """
  @spec manifest_file() :: String.t()
  def manifest_file, do: Path.join(Mix.Project.manifest_path(), "compile.scry")

  @doc """
  Runs the configured analyses against the project's compiled beams.

  Options:

  - `:manifest` (required) — the manifest path for cross-run
    incrementality.
  - `:force` — skip the warm start and recompute everything (default
    `false`).
  """
  @spec run(Scry.Config.t(), keyword()) :: Result.t()
  def run(%Scry.Config{} = config, opts) do
    manifest_path = Keyword.fetch!(opts, :manifest)
    force? = Keyword.get(opts, :force, false)

    db = Database.new()

    try do
      :ok = Roux.Lang.register_module(db, Scry.Frontend)
      :ok = Roux.Lang.register_module(db, Scry.Analysis)

      prior_sources = warm_start(db, manifest_path, force?)

      %{modules: discovered, ignored: ignored, duplicates: duplicates, apps: apps} =
        Scry.Scanner.scan(config)

      %{sources: sources, changed: changed, removed: removed, ignored_moved?: ignored_moved?} =
        Scry.Scanner.sync(db, discovered, prior_sources, ignored)

      souffle? = Argus.Souffle.available?()
      env = sync_environment(db, config, souffle?, apps)
      if env.fingerprint_changed?, do: :ok = drop_joined_extractions(db)

      # A module whose extraction failed last run is extracted again: a
      # timeout under load is not a fact about the beam.
      retried = retry_failed_extractions(db, discovered)

      {findings_by_file, degraded, extraction_errors} =
        if souffle? do
          cold? = force? or prior_sources == %{} or env.fingerprint_changed?
          plan = extraction_plan(discovered, cold?, changed ++ retried, env.moved_producers)
          analyze(db, config, discovered, plan)
        else
          {%{}, [], []}
        end

      changed? =
        force? or prior_sources == %{} or env.moved? or ignored_moved? or
          Enum.any?([changed, removed, retried, extraction_errors], &(&1 != []))

      # Written even when analyses degraded: the input syncs stay warm.
      # Skipped when nothing moved: no input changed, so no revision
      # advanced and every entry is as the manifest already has it —
      # rewriting it was most of a warm run.
      if changed?, do: :ok = Manifest.write(db, sources, manifest_path)

      %Result{
        findings_by_file: findings_by_file,
        degraded: degraded,
        extraction_errors: extraction_errors,
        duplicates: duplicates,
        souffle_missing?: not souffle?,
        changed?: changed?
      }
    after
      Database.shutdown(db)
      Roux.Runtime.drop_cached_values(db)
    end
  end

  # The inputs that describe the run rather than the beams: the
  # environment fingerprint, the project root, argus's producers and
  # code, and — with a solver — the rules digests. `moved?` when any of
  # them, or an analysis without a memo from the last run, means this
  # run has something to write down; `moved_producers` are the producers
  # whose rows every module needs extracted again (their code moved, or
  # they are new).
  defp sync_environment(db, config, souffle?, apps) do
    fingerprint_changed? = set(db, :env_fingerprint, :all, Scry.Fingerprint.env())
    :ok = Input.set(db, :project_root, :all, File.cwd!())

    producers = Scry.Analysis.producers()
    producers_changed? = set(db, :producers, :all, producers)

    argus = Scry.Fingerprint.argus_code()
    argus_changed? = set(db, :argus_code, :all, argus)
    moved_producers = set_producer_digests(db, producers, apps, argus)

    # Only solves read the rules, and none is demanded without a solver.
    rules_changed? = souffle? and set_rules(db, config.analyses)

    # An analysis with no memo from the last run — first demanded, or
    # degraded then and so never persisted — solves this run even when
    # no input moved, and its result is worth writing down.
    unsolved? = souffle? and Enum.any?(config.analyses, &unsolved?(db, &1))

    %{
      fingerprint_changed?: fingerprint_changed?,
      moved_producers: Enum.sort(moved_producers),
      moved?:
        fingerprint_changed? or producers_changed? or moved_producers != [] or argus_changed? or
          rules_changed? or unsolved?
    }
  end

  # The graph joins a module's producers where it needs them and never
  # demands `module_extraction`, the join memoized. A manifest written
  # before it did holds one per module, a copy of every row, and the
  # queries that read it (the semantic digest, the line table) still
  # list it among their dependencies: validating one of them would
  # compute the join again, and keep it. They go together, before the
  # graph is demanded, and the readers are recomputed from the
  # producers. Run when the environment moved (a scry upgrade moves it),
  # when every query above the extractions runs again anyway.
  @joined [:module_extraction, :module_semantic_facts, :module_line_table]

  defp drop_joined_extractions(db) do
    for module <- Input.keys(db, :beam_meta), query <- @joined do
      :ok = Memo.delete(db, {query, module})
    end

    :ok
  end

  # Sets each producer's digest; returns the producers whose digest moved.
  # Taking them walks each producer's code in a fresh VM, most of what a
  # warm run would add; while the stamp they are a function of holds
  # (`Scry.Fingerprint.producer_stamp/2`), the last run's stand.
  defp set_producer_digests(db, producers, apps, argus) do
    stamp = Scry.Fingerprint.producer_stamp(argus, apps)

    digests =
      case stored_digests(db, producers, stamp) do
        {:ok, stored} -> stored
        :stale -> Scry.Fingerprint.producers(producers, apps)
      end

    :ok = Input.set(db, :producer_stamp, :all, stamp)
    for {producer, digest} <- digests, set(db, :producer_digest, producer, digest), do: producer
  end

  defp stored_digests(_db, _producers, nil = _stamp), do: :stale

  defp stored_digests(db, producers, stamp) do
    stored =
      for producer <- producers,
          {:ok, digest} <- [Input.fetch(db, :producer_digest, producer)],
          into: %{},
          do: {producer, digest}

    if Input.fetch(db, :producer_stamp, :all) == {:ok, stamp} and
         map_size(stored) == length(producers),
       do: {:ok, stored},
       else: :stale
  end

  # Sets an input; true when its value moved.
  defp set(db, input, key, value) do
    moved? = Input.fetch(db, input, key) != {:ok, value}
    :ok = Input.set(db, input, key, value)
    moved?
  end

  # What to extract ahead of the graph, `module => producers | :all`:
  # every producer of every module on a cold run; otherwise every
  # producer of a module whose beam changed or whose last extraction
  # failed, and the moved producers of every other module.
  defp extraction_plan(discovered, true = _cold?, _changed, _moved_producers),
    do: Map.new(discovered, fn {module, _path} -> {module, :all} end)

  defp extraction_plan(discovered, false = _cold?, changed, moved_producers) do
    moved =
      if moved_producers == [],
        do: %{},
        else: Map.new(discovered, fn {module, _path} -> {module, moved_producers} end)

    for module <- changed, Map.has_key?(discovered, module), into: moved, do: {module, :all}
  end

  # Extracts `to_extract` ahead of the graph, then demands every
  # analysis. A failed solve is not a fact about the program — a solver
  # that crashed or timed out, a rules file it could not load — and a
  # memo of it would be replayed by every later run until an input above
  # it moved: out of the database before the manifest sees it.
  defp analyze(db, config, discovered, plan) do
    :ok = prewarm(db, discovered, plan)
    :ok = Scry.Priors.sync(db, config)
    {findings_by_file, degraded} = demand(db, config.analyses)
    _unclaimed = Scry.Analysis.drop_prewarmed()
    if degraded != [], do: :ok = drop_degraded(db, config.analyses)

    extraction_errors = Scry.Analysis.extraction_errors(db, :all)

    failed =
      for %{module: module} <- extraction_errors, module != nil, uniq: true, do: module

    :ok = Input.set(db, :failed_extractions, :all, Enum.sort(failed))
    {findings_by_file, degraded, extraction_errors}
  end

  # Every module's extraction attempt: 0 when first seen, a fresh value
  # for a module the last run could not extract — which re-runs its
  # extraction (and only its: the result backdates wherever it comes out
  # the same) — and otherwise what it was. Returns the modules retried.
  defp retry_failed_extractions(db, discovered) do
    failed =
      case Input.fetch(db, :failed_extractions, :all) do
        {:ok, modules} -> modules
        :error -> []
      end

    for module <- discovered |> Map.keys() |> Enum.sort(), reduce: [] do
      retried ->
        cond do
          module in failed ->
            :ok = Input.set(db, :extraction_attempt, module, System.unique_integer([:positive]))
            [module | retried]

          # A value set before stays: resetting it would re-extract the
          # module once more after a retry succeeded.
          Input.exists?(db, :extraction_attempt, module) ->
            retried

          true ->
            :ok = Input.set(db, :extraction_attempt, module, 0)
            retried
        end
    end
  end

  defp unsolved?(db, analysis) do
    Memo.changed_at(db, {:analysis_diagnostics, analysis}) == :miss
  end

  # The queries whose error values are failures of the run rather than
  # facts about the program.
  @degradable [:analysis_input_relations, :analysis_facts_dir, :souffle_solve]

  # Deletes every error-valued memo of a degradable query, and every memo
  # that depends on one, transitively — a dependent left behind would be
  # served on the next run without its dependency ever being revisited
  # (roux skips validating an entry no input of its durability moved
  # under).
  defp drop_degraded(db, analyses) do
    roots =
      for key <-
            [{:stage0_facts, :all}, {:points_to_facts, :all}] ++
              for(q <- @degradable, a <- analyses, do: {q, a}),
          match?({:ok, %Memo.Entry{value: {:error, _}}}, Memo.get(db, key)),
          do: key

    dependents =
      Memo.reduce_entries(db, %{}, fn {key, entry}, acc ->
        Enum.reduce(entry.dependencies, acc, fn dep, acc ->
          Map.update(acc, dep, [key], &[key | &1])
        end)
      end)

    roots
    |> closure(dependents, %{})
    |> Enum.each(fn {key, true} -> :ok = Memo.delete(db, key) end)
  end

  # `seen` is a map, not a MapSet: dialyzer cannot follow an opaque set
  # through the recursion.
  defp closure([], _dependents, seen), do: seen

  defp closure([key | rest], dependents, seen) when is_map_key(seen, key),
    do: closure(rest, dependents, seen)

  defp closure([key | rest], dependents, seen),
    do: closure(Map.get(dependents, key, []) ++ rest, dependents, Map.put(seen, key, true))

  # Sets each demanded analysis's rules digest (and stage 0's); true when
  # any moved.
  defp set_rules(db, analyses) do
    analyses
    |> Scry.Fingerprint.rules()
    |> Enum.reduce(false, fn {key, digest}, changed? ->
      set(db, :rules_digest, key, digest) or changed?
    end)
  end

  # The extractions whose memo cannot be a hit (`extraction_plan/4`),
  # run across the schedulers before the graph asks for them one at a
  # time.
  defp prewarm(_db, _discovered, plan) when map_size(plan) == 0, do: :ok

  defp prewarm(db, discovered, plan) do
    plan
    |> Map.new(fn
      {module, :all} -> {module, Map.fetch!(discovered, module)}
      {module, producers} -> {module, {Map.fetch!(discovered, module), producers}}
    end)
    |> Scry.Analysis.prewarm_extractions(db)
  end

  defp warm_start(_db, _manifest_path, true), do: %{}

  defp warm_start(db, manifest_path, false) do
    case Manifest.load(manifest_path) do
      {:ok, data} ->
        :ok = Manifest.restore(db, data)
        Map.get(data, :sources, %{})

      :error ->
        %{}
    end
  end

  # The analyses solve concurrently: each is its own Souffle process, and
  # they share everything upstream of their fact directories, which roux
  # computes once for whichever demands it first. The program's merged
  # relations are demanded here first, in this process, because the
  # prewarmed extractions wait in its dictionary — a task demanding them
  # would extract again.
  @doc false
  @spec demand(Database.t(), [atom()]) ::
          {%{optional(String.t()) => [map()]}, [%{analysis: atom(), reason: term()}]}
  def demand(db, analyses) do
    _relations = Scry.Analysis.program_relation_facts(db, :all)

    results =
      analyses
      |> Task.async_stream(
        &{&1, diagnostics(db, &1)},
        max_concurrency: System.schedulers_online(),
        ordered: true,
        # Each solve is bounded by argus's own Souffle timeout.
        timeout: :infinity
      )
      |> Enum.map(fn {:ok, result} -> result end)

    findings =
      for {_analysis, {:ok, by_file}} <- results, reduce: %{} do
        acc -> Map.merge(acc, by_file, fn _file, a, b -> a ++ b end)
      end

    degraded =
      for {analysis, {:error, reason}} <- results, do: %{analysis: analysis, reason: reason}

    {findings, degraded}
  end

  # An analysis that raises — argus rules and code out of step, a bug —
  # degrades like one whose solver failed, and the others still report.
  # Nothing is memoized for it, so the next run tries again.
  defp diagnostics(db, analysis) do
    Scry.Analysis.analysis_diagnostics(db, analysis)
  rescue
    exception -> {:error, {:crashed, Exception.format_banner(:error, exception, __STACKTRACE__)}}
  end
end
