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

    @enforce_keys [:findings_by_file, :degraded, :souffle_missing?, :changed?]
    defstruct [:findings_by_file, :degraded, :souffle_missing?, :changed?]

    @type t :: %__MODULE__{
            findings_by_file: %{optional(String.t()) => [map()]},
            degraded: [%{analysis: atom(), reason: term()}],
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

      discovered = Scry.Scanner.scan(config)

      %{sources: sources, changed: changed, removed: removed} =
        Scry.Scanner.sync(db, discovered, prior_sources)

      souffle? = Argus.Souffle.available?()

      fingerprint = Scry.Fingerprint.env()
      fingerprint_changed? = Input.fetch(db, :env_fingerprint, :all) != {:ok, fingerprint}
      :ok = Input.set(db, :env_fingerprint, :all, fingerprint)
      :ok = Input.set(db, :project_root, :all, File.cwd!())

      # Only solves read the rules, and none is demanded without a solver.
      rules_changed? = souffle? and set_rules(db, config.analyses)

      # An analysis with no memo from the last run — first demanded, or
      # degraded then and so never persisted — solves this run even when
      # no input moved, and its result is worth writing down.
      unsolved? = souffle? and Enum.any?(config.analyses, &unsolved?(db, &1))

      {findings_by_file, degraded} =
        if souffle? do
          cold? = force? or prior_sources == %{} or fingerprint_changed?
          analyze(db, config, discovered, if(cold?, do: Map.keys(discovered), else: changed))
        else
          {%{}, []}
        end

      changed? =
        force? or prior_sources == %{} or changed != [] or removed != [] or
          fingerprint_changed? or rules_changed? or unsolved?

      # Written even when analyses degraded: the input syncs stay warm.
      # Skipped when nothing moved: no input changed, so no revision
      # advanced and every entry is as the manifest already has it —
      # rewriting it was most of a warm run.
      if changed?, do: :ok = Manifest.write(db, sources, manifest_path)

      %Result{
        findings_by_file: findings_by_file,
        degraded: degraded,
        souffle_missing?: not souffle?,
        changed?: changed?
      }
    after
      Database.shutdown(db)
      Roux.Runtime.drop_cached_values(db)
    end
  end

  # Extracts `to_extract` ahead of the graph, then demands every
  # analysis. A failed solve is not a fact about the program — a solver
  # that crashed or timed out, a rules file it could not load — and a
  # memo of it would be replayed by every later run until an input above
  # it moved: out of the database before the manifest sees it.
  defp analyze(db, config, discovered, to_extract) do
    :ok = prewarm(db, discovered, to_extract)
    :ok = Scry.Priors.sync(db, config)
    {findings_by_file, degraded} = demand(db, config.analyses)
    if degraded != [], do: :ok = drop_degraded(db, config.analyses)
    {findings_by_file, degraded}
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
      for key <- [{:stage0_facts, :all} | for(q <- @degradable, a <- analyses, do: {q, a})],
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
      moved? = Input.fetch(db, :rules_digest, key) != {:ok, digest}
      :ok = Input.set(db, :rules_digest, key, digest)
      changed? or moved?
    end)
  end

  # The modules whose extraction memo cannot be a hit — every module on a
  # cold run, the changed ones otherwise — extracted across the schedulers
  # before the graph asks for them one at a time.
  defp prewarm(_db, _discovered, []), do: :ok

  defp prewarm(db, discovered, modules) do
    discovered
    |> Map.take(modules)
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

  # Sequential demand: per-analysis solves are sub-second, and on warm
  # runs these are memo hits. Parallel solves are a measured follow-up.
  defp demand(db, analyses) do
    {findings, degraded} =
      Enum.reduce(analyses, {%{}, []}, fn analysis, {acc, degraded} ->
        case Scry.Analysis.analysis_diagnostics(db, analysis) do
          {:ok, by_file} ->
            {Map.merge(acc, by_file, fn _file, a, b -> a ++ b end), degraded}

          {:error, reason} ->
            {acc, [%{analysis: analysis, reason: reason} | degraded]}
        end
      end)

    {findings, Enum.reverse(degraded)}
  end
end
