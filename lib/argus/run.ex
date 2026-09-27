defmodule Argus.Run do
  @moduledoc """
  `Argus.run_analyses/2`, `Argus.analyze/3` and `Argus.Analysis.extract_facts/3`
  over the query graph (`Argus.Graph`).

  Each call opens a session of its own over the blob store
  (`Argus.Graph.store/0`, or `store:`), sets the modules as one program
  (`:batch`), demands what it answers and closes it: without a
  `manifest:` nothing is kept but the store, which is what the next
  call finds again — each module's facts by its content and the code
  extracting it, each solve by the digests of what it reads. Under
  `ARGUS_NO_CACHE` the store is a temporary one, removed when the call
  returns.

  Each finding and related frame says where it is (`file`, `line`,
  `end_line`: `Argus.Located`), refined by its source as every
  frontend's report is (`Argus.Located.refine/1`): the line a fragment
  names, the end of an open span, and the keyword in place of `{guard}`
  in the prose.

  ## Options

  Besides `:analyses`, `:souffle_bin`, `:souffle_timeout`,
  `:concurrency`, `:priors` and `:priors_opts` (`Argus.Findings.run/2`):

    * `:store` — the blob store: a `Roux.Blob`, or the root of one.
    * `:manifest` — where the graph is kept between calls: the call
      restores it, and keeps it there after (`Roux.Session`). A beam
      whose file has not moved is not read again, and only what an edit
      reached runs. Without one (the default) nothing is kept but the
      store.
    * `:stamps` — the code directories' stamps
      (`Argus.Graph.set_environment/2`): read when the call keeps a
      manifest, unless given (`Argus.Graph.Environment.stamps/1`, read
      once for many calls in one VM).

  The batch pipeline's options went with it in 0.20: each raises,
  naming what replaces it (`check_options!/1`).
  """

  alias Argus.Analysis
  alias Argus.Analysis.Sets
  alias Argus.Findings
  alias Argus.Findings.Degradation
  alias Argus.Graph
  alias Argus.Located
  alias Argus.Pipeline.Disassemble

  @program :batch
  @severity_rank %{error: 0, warning: 1, info: 2}

  @doc "`Argus.run_analyses/2` over the graph."
  @spec run_analyses([atom() | String.t()], keyword()) :: {:ok, Findings.t()} | {:error, term()}
  def run_analyses(modules, opts) do
    check_options!(opts)
    Argus.Priors.check!(opts)
    {selection, opts} = Keyword.pop(opts, :analyses, :all)

    with {:ok, requests} <- Sets.resolve(selection),
         :ok <- ensure_souffle(opts) do
      names = Enum.map(requests, & &1.name())

      if names == [] do
        {:ok, %Findings{}}
      else
        in_session(modules, names, opts, fn db -> findings(db, names, opts) end)
      end
    end
  end

  @doc "`Argus.analyze/3` over the graph: the analysis's output rows."
  @spec analyze([atom() | String.t()], Analysis.analysis(), keyword()) ::
          {:ok, Analysis.result()} | {:error, term()}
  def analyze(modules, analysis, opts) do
    check_options!(opts)
    Argus.Priors.check!(opts)

    with {:ok, _path} <- Analysis.Catalog.rules_path(analysis) do
      in_session(modules, [analysis], opts, fn db ->
        Graph.Findings.results(db, @program, analysis)
      end)
    end
  end

  @doc """
  `Argus.Analysis.extract_facts/3` over the graph: a directory holding a
  file for every relation of the schema, each with the rows of the
  producers `analyses` run, as the batch pipeline writes it (the same
  rows, in an order of the graph's own; `line_info` included, the
  imprecision trace only for `:coverage`), stage 0's call graph, and —
  unless `points_to: :deferred`, and when an analysis reads it — the
  points-to stage, each a hard link into the store. The relations only
  a pipeline process reads (`Argus.Schema.in_process_only/0`) are empty:
  the graph keeps none. The caller removes the directory (and its
  parent) as any other.
  """
  @spec extract_facts([atom() | String.t()], [Analysis.analysis()], keyword()) ::
          {:ok, Path.t()} | {:error, term()}
  def extract_facts(modules, analyses, opts) do
    check_options!(opts)
    Argus.Priors.check!(opts)

    in_session(modules, analyses, opts, fn db -> materialize(db, analyses, opts) end)
  end

  # ── Options ─────────────────────────────────────────────────────────

  # What the batch pipeline took, gone with it in 0.20, and what a
  # caller does instead.
  @gone [
    backend: "argus has one backend since 0.20, the query graph: drop `backend:`",
    facts_dir:
      "a facts directory is no longer read back: write one with " <>
        "Argus.Analysis.extract_facts/3 (or by hand) and solve it with Argus.Analysis.run_rules/3",
    cache:
      "facts and solves are kept in the blob store: `store:` names one (a Roux.Blob, or " <>
        "its root), and `manifest:` keeps the graph between calls",
    solve_cache: "solves are kept in the blob store's action cache: `store:` names one",
    extractors:
      "every built-in extractor runs, once for every analysis: for another extractor's " <>
        "rows, extract with Argus.Pipeline.extract/2 and solve with Argus.Analysis.run_rules/3",
    relations:
      "a solve reads every relation its program reads: for a facts directory, use " <>
        "Argus.Analysis.extract_facts/3"
  ]

  @doc """
  Raises `ArgumentError` for an option the batch pipeline took and 0.20
  removed with it (`:backend`, `:facts_dir`, `:cache`, `:solve_cache`,
  `:extractors`, `:relations`), naming what replaces it.

      iex> Argus.Run.check_options!(analyses: [:mailbox], store: "store")
      :ok
  """
  @spec check_options!(keyword()) :: :ok
  def check_options!(opts) when is_list(opts) do
    case Enum.find(opts, fn {key, _value} -> Keyword.has_key?(@gone, key) end) do
      nil -> :ok
      {key, _value} -> raise ArgumentError, "#{inspect(key)}: " <> Keyword.fetch!(@gone, key)
    end
  end

  # A session over the modules as the program, with the environment and
  # the priors set; `fun` runs with its database. With a manifest the
  # session is restored from it and kept in it after `fun`.
  defp in_session(modules, analyses, opts, fun) do
    with {:ok, beams} <- Disassemble.resolve_paths(modules) do
      manifest = Keyword.get(opts, :manifest)
      session = Graph.open(store: Keyword.get(opts, :store), manifest: manifest)

      try do
        db = session.db

        meta =
          if manifest do
            {_keys, meta} = Graph.sync_program(db, @program, beams, session.sources)
            meta
          else
            _keys = Graph.set_program(db, @program, beams)
            %{}
          end

        trees = for {:custom, path} <- analyses, do: Graph.Programs.tree({:custom, path})

        # A session never kept has no use for the code directories'
        # stamps (`Argus.Graph.set_environment/2`); a kept one reads
        # them, unless the caller read them already.
        stamps = Keyword.get(opts, :stamps, manifest != nil)

        _moved =
          Graph.set_environment(
            db,
            [trees: trees, stamps: stamps] ++
              Keyword.take(opts, [:souffle_bin, :souffle_timeout])
          )

        :ok = Graph.set_priors(db, @program, priors(opts))
        answer = fun.(db)
        {_status, _session} = Roux.Session.commit(session, meta)
        answer
      after
        Roux.Session.close(session)
      end
    end
  end

  defp priors(opts) do
    case Keyword.get(opts, :priors, :off) do
      :off -> :off
      mode -> %{mode: mode, opts: Keyword.get(opts, :priors_opts, [])}
    end
  end

  defp findings(db, names, opts) do
    outcomes =
      names
      |> Task.async_stream(&run_one(db, &1),
        max_concurrency: Keyword.get(opts, :concurrency, min(System.schedulers_online(), 4)),
        ordered: true,
        timeout: :infinity
      )
      |> Enum.flat_map(fn {:ok, outcomes} -> outcomes end)

    # Every analysis's findings refined by their sources in one pass, each
    # file read once for all of them (`Argus.Locate.Source.within/1`).
    outcomes =
      Argus.Locate.Source.within(fn ->
        Enum.map(outcomes, fn
          {:ran, entry, located} ->
            {:ran, entry, Enum.map(located, &(&1 |> Located.refine() |> Located.to_finding()))}

          degraded ->
            degraded
        end)
      end)

    errors = Graph.Findings.extraction_errors(db, @program)
    {:ok, %{collect(outcomes) | extraction_errors: errors}}
  end

  defp run_one(db, name) do
    {elapsed_us, result} =
      :timer.tc(fn ->
        {Graph.Locate.located(db, {@program, name}), findings_of(db, name)}
      end)

    duration_ms = div(elapsed_us, 1000)

    case result do
      {{:ok, located}, {:ok, _findings, failures}} ->
        # Placed; refined by the caller (`findings/3`).
        ran =
          {:ran, %{analysis: name, duration_ms: duration_ms, finding_count: length(located)},
           located}

        [ran | Degradation.rows(name, failures)]

      {{:error, reason}, _} ->
        [{:degraded, %{analysis: name, reason: reason, detail: Degradation.detail(name, reason)}}]
    end
  rescue
    exception ->
      reason = {:crashed, Exception.format_banner(:error, exception, __STACKTRACE__)}
      [{:degraded, %{analysis: name, reason: reason, detail: Degradation.detail(name, reason)}}]
  end

  # The findings `located` placed, read again for the rows a builder
  # raised on: a hit, the query having just run.
  defp findings_of(db, name), do: Graph.Findings.findings(db, {@program, name})

  defp collect(outcomes) do
    findings =
      outcomes
      |> Enum.flat_map(fn
        {:ran, _entry, findings} -> findings
        {:degraded, _note} -> []
      end)
      |> Enum.sort_by(fn finding ->
        {Map.fetch!(@severity_rank, finding.severity), finding.analysis, finding.title,
         finding.detail}
      end)

    ran = for {:ran, entry, _findings} <- outcomes, do: entry
    degraded = for {:degraded, note} <- outcomes, do: note

    %Findings{findings: findings, ran: ran, degraded: degraded}
  end

  defp ensure_souffle(opts) do
    cond do
      Keyword.has_key?(opts, :souffle_bin) -> :ok
      Argus.Souffle.available?() -> :ok
      true -> {:error, :souffle_not_found}
    end
  end

  # ── Facts directory ────────────────────────────────────────────────

  # The directory the batch pipeline writes for `analyses`: every
  # relation of the schema, each holding the rows of the producers those
  # analyses run (the base, the call-argument extractor and each one's
  # extractors), `line_info` among them, the imprecision trace only for
  # `:coverage`; the relations only a process of the pipeline reads
  # (`Argus.Schema.in_process_only/0`) are empty, as the graph keeps none.
  defp materialize(db, analyses, opts) do
    extracted = Argus.Schema.names() -- Argus.Schema.in_process_only()
    traced? = :coverage in analyses

    {relations, empty} =
      Enum.reduce(extracted, {[], Argus.Schema.in_process_only()}, fn
        :imprecision, {relations, empty} when not traced? ->
          {relations, [:imprecision | empty]}

        :line_info, {relations, empty} ->
          {[{:line_info, Graph.Relations.line_info(db, @program)} | relations], empty}

        relation, {relations, empty} ->
          {[{relation, Graph.Relations.relation(db, {@program, relation})} | relations], empty}
      end)

    with {:ok, work} <- work_dir(),
         dir = Path.join(work, "facts"),
         :ok <- File.mkdir_p(dir),
         {:ok, files} <-
           Graph.Relations.files(db, @program, Enum.reverse(relations), producers(analyses)),
         :ok <- link_all(db, files, dir),
         :ok <- empty_files(empty, dir),
         :ok <- stage(db, :stage0, dir),
         :ok <- points_to(db, analyses, dir, opts) do
      {:ok, dir}
    end
  end

  # The producers the batch pipeline runs for `analyses`
  # (`Argus.Analysis.Extraction`'s defaults): the base, the call-argument
  # extractor every analysis reads through, and each built-in's own.
  defp producers(analyses) do
    extractors =
      for {:ok, module} <- Enum.map(analyses, &analysis_module/1),
          extractor <- module.extractors(),
          do: extractor

    Enum.uniq([:base, Argus.Extractors.CallArgs | extractors])
  end

  defp analysis_module({:custom, _path}), do: :error
  defp analysis_module(name), do: Analysis.Catalog.fetch(name)

  defp link_all(db, files, dir) do
    Enum.reduce_while(files, :ok, fn {relation, digest}, :ok ->
      case Roux.Blob.link(db.blob, digest, Path.join(dir, "#{relation}.facts")) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:link_failed, relation, reason}}}
      end
    end)
  end

  defp empty_files(relations, dir) do
    Enum.reduce_while(relations, :ok, fn relation, :ok ->
      case File.write(Path.join(dir, "#{relation}.facts"), "") do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:write_failed, relation, reason}}}
      end
    end)
  end

  defp stage(db, stage, dir) do
    case Graph.Solve.stage(db, {@program, stage}) do
      {:ok, %{outputs: outputs}} ->
        outputs
        |> Enum.filter(fn {file, _} -> Path.extname(file) == ".facts" end)
        |> Enum.reduce_while(:ok, fn {file, digest}, :ok ->
          target = Path.join(dir, file)
          _ = File.rm(target)

          case Roux.Blob.link(db.blob, digest, target) do
            :ok -> {:cont, :ok}
            {:error, reason} -> {:halt, {:error, {stage, {:link_failed, file, reason}}}}
          end
        end)

      {:error, {:points_to, _}} = error ->
        error

      {:error, reason} ->
        {:error, {stage, reason}}
    end
  end

  defp points_to(db, analyses, dir, opts) do
    if Keyword.get(opts, :points_to, :derive) == :derive and
         Enum.any?(analyses, &Analysis.Extraction.reads_points_to?/1),
       do: stage(db, :points_to, dir),
       else: :ok
  end

  defp work_dir do
    dir =
      Path.join(System.tmp_dir!(), "argus_#{:os.getpid()}_#{System.unique_integer([:positive])}")

    case File.mkdir_p(dir) do
      :ok -> {:ok, dir}
      {:error, reason} -> {:error, {:mkdir_failed, reason}}
    end
  end
end
