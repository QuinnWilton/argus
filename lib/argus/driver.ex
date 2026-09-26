defmodule Argus.Driver do
  @moduledoc """
  The shared driver core for `mix compile.scry` and `mix scry`: database
  lifecycle, manifest warm start, input sync, the souffle gate, and
  analysis demand.

  One `Roux.Database` lives for the duration of a run; the manifest is
  the only continuity across OS processes. The manifest is written even
  when analyses degrade — the input syncs done this run stay warm, so
  error-loop editing stays incremental. It records the layout of the
  graph that wrote it, and a manifest of another layout is dropped
  unread: the run is cold.

  When souffle is missing, no solve is demanded at all: a memoized
  `{:error, :souffle_not_found}` would only heal when an input above it
  changed, so the degraded path never lets one into the manifest. The
  souffle version rides every `:rules_digest` (`Argus.Graph.Environment`), so
  upgrading the solver re-solves without re-extracting.
  """

  alias Roux.Database
  alias Roux.Input
  alias Roux.Lang.Manifest
  alias Roux.Memo

  alias Argus.Driver.Result

  @doc """
  The manifest path shared by `mix compile.scry` and `mix scry` — one
  incremental state, whichever entry point drives it.
  """
  @spec manifest_file() :: String.t()
  def manifest_file, do: Path.join(Mix.Project.manifest_path(), "compile.scry")

  @doc """
  The store beside the manifest (`Argus.Cache`'s layout) where argus
  keeps what outlives a VM for this project: each dependency ebin's
  beam hashes and argus's own (`ebins/`), which the fingerprints would
  otherwise read every beam for (`Argus.Graph.Environment.env/2`,
  `Argus.Graph.Environment.argus_code/1`), and the relations each Datalog
  program loads with the solver's version (`programs/`,
  `Argus.Graph.Environment.rules/2`), which a warm run would otherwise start
  the solver for. Shared by `mix compile.scry` and `mix scry`, and
  removed with the manifest.
  """
  @spec cache_dir() :: String.t()
  def cache_dir, do: Path.join(Mix.Project.manifest_path(), "compile.scry.cache")

  @doc """
  Runs the configured analyses against the project's compiled beams.

  Options:

  - `:manifest` (required) — the manifest path for cross-run
    incrementality.
  - `:force` — skip the warm start and recompute everything (default
    `false`); what the store keeps under a stamp (the beam hashes, the
    solver's version) is dropped and kept again.
  - `:cache` — the store argus keeps across runs (`cache_dir/0`), or
    nil (the default) for none: every run then hashes every dependency
    and argus beam again, and asks the solver.
  """
  @spec run(Argus.Config.t(), keyword()) :: Result.t()
  def run(%Argus.Config{} = config, opts) do
    manifest_path = Keyword.fetch!(opts, :manifest)
    force? = Keyword.get(opts, :force, false)
    cache = Keyword.get(opts, :cache)

    {db, prior_sources} = open(manifest_path, force?)

    try do
      %{modules: discovered, ignored: ignored, duplicates: duplicates, apps: apps} =
        Argus.Project.Scan.scan(config)

      %{sources: sources, changed: changed, removed: removed, ignored_moved?: ignored_moved?} =
        Argus.Project.Scan.sync(db, discovered, prior_sources, ignored)

      souffle? = Argus.Souffle.available?()
      env = sync_environment(db, config, souffle?, apps, cache: cache, refresh: force?)

      # A module whose extraction failed last run is extracted again: a
      # timeout under load is not a fact about the beam.
      retried = retry_failed_extractions(db, discovered)

      {located, extraction_errors} =
        if souffle? do
          # What every extraction reads moved: every module is extracted
          # again, across the schedulers.
          cold? =
            force? or prior_sources == %{} or env.fingerprint_changed? or
              env.extraction_changed?

          to_extract =
            if cold?,
              do: Map.keys(discovered),
              else:
                Enum.uniq(changed ++ retried ++ schema_moved(db, discovered, env.argus_changed?))

          analyze(db, config, discovered, to_extract)
        else
          {%{}, []}
        end

      changed? =
        force? or prior_sources == %{} or env.moved? or ignored_moved? or
          Enum.any?([changed, removed, retried, extraction_errors], &(&1 != []))

      # Written even when analyses degraded: the input syncs stay warm.
      # Skipped when nothing moved: no input changed, so no revision
      # advanced and every entry is as the manifest already has it —
      # rewriting it was most of a warm run.
      if changed?, do: :ok = Manifest.write(db, sources, manifest_path)

      notices =
        if(souffle?, do: [], else: [:souffle_missing]) ++
          Enum.map(extraction_errors, &{:extraction_error, &1}) ++
          Enum.map(duplicates, &{:duplicate, &1})

      %Result{located: located, notices: notices, changed?: changed?}
    after
      close(db)
    end
  end

  # The layout of the graph a manifest holds: the queries it memoizes,
  # their keys, and what each one's value is. A manifest another layout
  # wrote is not read at all: its memos can name a query this graph does
  # not define (a scry that memoized extraction per argus producer left
  # `producer_extraction` entries, which its semantic digests depend on,
  # and validating one would run a query that is not there), or one it
  # defines with another meaning. Bump it with any change that renames,
  # removes or re-keys a query, or changes what a memo holds. A manifest
  # without one predates it.
  @layout 1

  # A database with both layers registered and, unless `force?`, the
  # manifest's state restored into it, with the sources the manifest
  # recorded. A manifest of another layout is dropped whole — its memos,
  # its interned symbols, its revisions — and the run is cold.
  defp open(manifest_path, force?) do
    db = Database.new()

    try do
      :ok = Roux.Lang.register_module(db, Argus.Graph.Frontend)
      :ok = Roux.Lang.register_module(db, Argus.Graph)
      warm_start(db, manifest_path, force?)
    rescue
      exception ->
        close(db)
        reraise exception, __STACKTRACE__
    else
      {:ok, sources} ->
        {db, sources}

      :other_layout ->
        close(db)
        open(manifest_path, true)
    end
  end

  defp close(db) do
    Database.shutdown(db)
    Roux.Runtime.drop_cached_values(db)
  end

  # The inputs that describe the run rather than the beams: the
  # environment fingerprint, argus's code (what extraction runs, and all
  # of it), the project root, and — with a solver — the rules digests.
  # `moved?` when any of them, or an analysis without a memo from the
  # last run, means this run has something to write down.
  defp sync_environment(db, config, souffle?, apps, env_opts) do
    :ok = Input.set(db, :graph_layout, :all, @layout)

    fingerprint_changed? =
      set(db, :env_fingerprint, :all, Argus.Graph.Environment.env(apps, env_opts))

    # A rebuilt dependency leaves its old beams' hashes behind; they go
    # once nothing has read them for an hour, all but each application's
    # three latest (`Argus.Cache.prune/2`). Looked at when the
    # environment moved, as it does when a rebuild changed code, rather
    # than on every run.
    if fingerprint_changed?, do: prune(env_opts[:cache])

    extraction_changed? =
      set(db, :extraction_code, :all, Argus.Graph.Environment.extraction_code())

    store = Keyword.take(env_opts, [:cache])
    argus_changed? = set(db, :argus_code, :all, Argus.Graph.Environment.argus_code(store))
    :ok = Input.set(db, :project_root, :all, File.cwd!())

    # Only solves read the rules, and none is demanded without a solver.
    rules_changed? = souffle? and set_rules(db, config.analyses, env_opts)

    # An analysis with no memo from the last run — first demanded, or
    # degraded then and so never persisted — solves this run even when
    # no input moved, and its result is worth writing down.
    unsolved? = souffle? and Enum.any?(config.analyses, &unsolved?(db, &1))

    %{
      fingerprint_changed?: fingerprint_changed?,
      extraction_changed?: extraction_changed?,
      argus_changed?: argus_changed?,
      moved?:
        fingerprint_changed? or extraction_changed? or argus_changed? or rules_changed? or
          unsolved?
    }
  end

  # A store that cannot be pruned (another user's files, a read-only
  # volume) costs disk space, not a run.
  defp prune(cache) do
    case Argus.Cache.store(cache: cache) do
      nil -> :ok
      store -> _pruned = Argus.Cache.prune(store)
    end

    :ok
  rescue
    File.Error -> :ok
  end

  # Sets an input; true when its value moved.
  defp set(db, input, key, value) do
    moved? = Input.fetch(db, input, key) != {:ok, value}
    :ok = Input.set(db, input, key, value)
    moved?
  end

  # Extracts `to_extract` ahead of the graph, then demands every
  # analysis. A failed solve is not a fact about the program — a solver
  # that crashed or timed out, a rules file it could not load — and a
  # memo of it would be replayed by every later run until an input above
  # it moved: out of the database before the manifest sees it.
  defp analyze(db, config, discovered, to_extract) do
    :ok = prewarm(db, discovered, to_extract)
    :ok = Argus.Graph.Priors.sync(db, config)
    located = demand(db, config.analyses, prewarmed?: to_extract != [])

    if Enum.any?(located, &match?({_analysis, {:error, _}}, &1)),
      do: :ok = drop_degraded(db, config.analyses)

    extraction_errors = Argus.Graph.extraction_errors(db, :all)

    failed =
      for %{module: module} <- extraction_errors, module != nil, uniq: true, do: module

    :ok = Input.set(db, :failed_extractions, :all, Enum.sort(failed))
    {located, extraction_errors}
  end

  # The modules whose last extraction read an entry of argus's schema
  # that reads otherwise now (`Argus.Graph`'s `schema_read`): the
  # graph would extract them again one at a time, as it validates them;
  # found here, they are extracted across the schedulers first. An entry
  # moves only with argus's code, so only then is this looked at, each
  # entry digested once whatever number of modules read it.
  defp schema_moved(_db, _discovered, false), do: []

  defp schema_moved(db, discovered, true) do
    reads_of =
      for module <- Map.keys(discovered),
          {:ok, dependencies} <- [Memo.dependencies(db, {:module_extraction, module})],
          do: {module, for({:schema_read, read} <- dependencies, do: read)}

    moved =
      reads_of
      |> Enum.flat_map(&elem(&1, 1))
      |> Enum.uniq()
      |> Enum.filter(&entry_moved?(db, &1))
      |> MapSet.new()

    for {module, reads} <- reads_of, Enum.any?(reads, &MapSet.member?(moved, &1)), do: module
  end

  # Whether the digest an entry's memo holds is not what it reads now.
  defp entry_moved?(db, read) do
    case Memo.get(db, {:schema_read, read}) do
      {:ok, %Memo.Entry{value: digest}} -> digest != Argus.Graph.schema_digest(read)
      :miss -> true
    end
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
    Memo.changed_at(db, {:located, analysis}) == :miss
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

  # Sets each demanded analysis's rules digest (and the stages'); true
  # when any moved.
  defp set_rules(db, analyses, opts) do
    analyses
    |> Argus.Graph.Environment.rules(Keyword.take(opts, [:cache, :refresh]))
    |> Enum.reduce(false, fn {key, digest}, changed? ->
      set(db, :rules_digest, key, digest) or changed?
    end)
  end

  # The modules whose extraction memo cannot be a hit — every module on a
  # cold run, the changed ones otherwise — extracted across the schedulers
  # before the graph asks for them one at a time.
  defp prewarm(_db, _discovered, []), do: :ok

  defp prewarm(db, discovered, modules) do
    discovered
    |> Map.take(modules)
    |> Argus.Graph.prewarm_extractions(db)
  end

  defp warm_start(_db, _manifest_path, true), do: {:ok, %{}}

  defp warm_start(db, manifest_path, false) do
    case Manifest.load(manifest_path) do
      {:ok, data} ->
        :ok = Manifest.restore(db, data)

        if Input.fetch(db, :graph_layout, :all) == {:ok, @layout},
          do: {:ok, Map.get(data, :sources, %{})},
          else: :other_layout

      :error ->
        {:ok, %{}}
    end
  end

  # The analyses solve concurrently: each is its own Souffle process, and
  # they share everything upstream of their fact directories, which roux
  # computes once for whichever demands it first. When extractions were
  # prewarmed (`prewarmed?: true`, the default), the program's merged
  # relations are demanded here first, in this process, because the
  # extractions wait in its dictionary — a task demanding them would
  # extract again. Otherwise the analyses validate them where they are:
  # served here, the relations — tens of megabytes on a large program —
  # would be copied onto this process's heap and kept there until the
  # run ends, for nothing (60 ms of a one-second warm run on a 350-module
  # project).
  @doc false
  @spec demand(Database.t(), [atom()], keyword()) ::
          %{optional(atom()) => {:ok, [Argus.Located.t()]} | {:error, term()}}
  def demand(db, analyses, opts \\ []) do
    if Keyword.get(opts, :prewarmed?, true),
      do: _ = Argus.Graph.program_relation_facts(db, :all)

    analyses
    |> Task.async_stream(
      &{&1, located(db, &1)},
      max_concurrency: System.schedulers_online(),
      ordered: true,
      # Each solve is bounded by argus's own Souffle timeout.
      timeout: :infinity
    )
    |> Map.new(fn {:ok, result} -> result end)
  end

  # An analysis that raises — argus rules and code out of step, a bug —
  # degrades like one whose solver failed, and the others still report.
  # Nothing is memoized for it, so the next run tries again.
  defp located(db, analysis) do
    Argus.Graph.located(db, analysis)
  rescue
    exception -> {:error, {:crashed, Exception.format_banner(:error, exception, __STACKTRACE__)}}
  end
end
