defmodule Argus.Run do
  @moduledoc """
  `Argus.run_analyses/2`, `Argus.analyze/3` and `Argus.Analysis.extract_facts/3`
  over the query graph (`Argus.Graph`): what they do with `backend: :graph`.

  Each call opens a session of its own over the blob store
  (`Argus.Graph.store/0`, or `store:`), sets the modules as one program
  (`:batch`), demands what it answers and closes it: without a
  `manifest:` nothing is kept but the store, which is what the next
  call finds again — each module's facts by its content and the code
  extracting it, each solve by the digests of what it reads. Under
  `ARGUS_NO_CACHE` the store is a temporary one, removed when the call
  returns.

  The answers are the batch backend's (`Argus.Findings.run/2`), relation
  for relation and finding for finding, except that each finding and
  related frame also says where it is (`file`, `line`, `end_line`:
  `Argus.Located`), which the batch backend leaves nil, and that the
  source has refined it as every frontend's report does
  (`Argus.Located.refine/1`): the line a fragment names, the end of an
  open span, and the keyword in place of `{guard}` in the prose.

  ## Options

  Besides what the batch backend takes (`:analyses`, `:souffle_bin`,
  `:souffle_timeout`, `:concurrency`, `:priors`, `:priors_opts`):

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

  The options that shape the batch backend's facts directory or its
  stores (`:facts_dir`, `:cache`, `:solve_cache`, `:extractors`,
  `:relations`) mean nothing here and are ignored: the graph extracts
  every producer once, for every analysis, and keeps what it made.
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
    with {:ok, _path} <- Analysis.Catalog.rules_path(analysis) do
      in_session(modules, [analysis], opts, fn db ->
        Graph.Findings.results(db, @program, analysis)
      end)
    end
  end

  @doc """
  `Argus.Analysis.extract_facts/3` over the graph: a directory holding a
  file for every relation of the schema (empty when it has no rows),
  stage 0's call graph, and — unless `points_to: :deferred`, and when an
  analysis reads it — the points-to stage, each a hard link into the
  store. The caller removes it (and its parent) as any other.
  """
  @spec extract_facts([atom() | String.t()], [Analysis.analysis()], keyword()) ::
          {:ok, Path.t()} | {:error, term()}
  def extract_facts(modules, analyses, opts) do
    in_session(modules, analyses, opts, fn db -> materialize(db, analyses, opts) end)
  end

  # ── Backends, as the environment picks them ────────────────────────

  @doc """
  The backend the environment asks the harnesses to run
  (`Argus.Test.Memo`, `Argus.Test.Batch`, `Argus.Corpus`):
  `ARGUS_BACKEND=graph` or `batch` (the default).
  """
  @spec env_backend() :: :batch | :graph
  def env_backend do
    case System.get_env("ARGUS_BACKEND") do
      value when value in [nil, "", "batch"] ->
        :batch

      "graph" ->
        :graph

      other ->
        raise ArgumentError, "ARGUS_BACKEND must be graph or batch, got: #{inspect(other)}"
    end
  end

  @doc """
  Whether `ARGUS_VERIFY_BACKEND=1` asks the harnesses to run every call
  both ways and compare (`both/2`).
  """
  @spec verify_backend?() :: boolean()
  def verify_backend?, do: System.get_env("ARGUS_VERIFY_BACKEND") in ["1", "true"]

  @doc """
  `run.(backend)` for the backend the environment asks for
  (`env_backend/0`); under `ARGUS_VERIFY_BACKEND`, for both, raising
  unless the two answers are the same in normal form (`normal_form/1`),
  relation by relation. Returns the answer of the backend asked for.
  """
  @spec both((:batch | :graph -> result), term()) :: result when result: term()
  def both(run, label) when is_function(run, 1) do
    if verify_backend?() do
      [batch, graph] =
        [:batch, :graph]
        |> Task.async_stream(run, timeout: :infinity, ordered: true)
        |> Enum.map(fn {:ok, answer} -> answer end)

      case differences(normal_form(batch), normal_form(graph)) do
        [] ->
          if env_backend() == :graph, do: graph, else: batch

        diff ->
          raise "the batch and graph backends disagree on #{inspect(label)}: " <>
                  inspect(diff, pretty: true, limit: :infinity)
      end
    else
      run.(env_backend())
    end
  end

  @doc """
  An answer of `Argus.run_analyses/2` or `Argus.analyze/3` in the form
  two backends are compared in: findings sorted by analysis, severity,
  title, mfa, instruction and anchor label, each without where it is
  (`file`, `line`, `end_line`, on it and its frames) nor the word its
  source put in its prose (`{guard}`, and the keywords the graph's
  refine step puts there, all read as `{guard}`); `ran` (without
  its duration), `degraded` and `extraction_errors` as sets; an
  analysis's rows as each relation's sorted, empty relations left out.
  An error is compared as it is.
  """
  @spec normal_form(term()) :: term()
  def normal_form({:ok, %Findings{} = found}) do
    {:ok,
     %{
       findings:
         found.findings
         |> Enum.map(&unplaced/1)
         |> Enum.sort_by(&{&1.analysis, &1.severity, &1.title, &1.mfa, &1.instr, &1.at_label, &1}),
       ran: MapSet.new(found.ran, &Map.delete(&1, :duration_ms)),
       degraded: MapSet.new(found.degraded),
       extraction_errors: MapSet.new(found.extraction_errors)
     }}
  end

  def normal_form({:ok, %{} = results}) do
    {:ok,
     for({relation, rows} <- results, rows != [], into: %{}, do: {relation, Enum.sort(rows)})}
  end

  def normal_form(other), do: other

  @places [:file, :line, :end_line]

  defp unplaced(finding) do
    finding
    |> Map.drop(@places)
    |> unguarded([:title, :detail, :at_label, :help])
    |> Map.update(:related, [], fn frames ->
      Enum.map(frames, &(&1 |> Map.drop(@places) |> unguarded([:label])))
    end)
  end

  # The words a source puts for `{guard}` (`Argus.Located.refine/1`),
  # read back as the placeholder on both sides: the batch backend has
  # no source and leaves it.
  @guard_words ~r/\{guard\}|\b(?:rescue|catch|after|handler)\b/

  defp unguarded(map, fields) do
    Enum.reduce(fields, map, fn field, map ->
      case Map.fetch(map, field) do
        {:ok, text} when is_binary(text) ->
          %{map | field => Regex.replace(@guard_words, text, "{guard}")}

        {:ok, texts} when is_list(texts) ->
          %{map | field => Enum.map(texts, &Regex.replace(@guard_words, &1, "{guard}"))}

        _absent_or_nil ->
          map
      end
    end)
  end

  # What two normal forms differ in: per relation (or part of a
  # findings answer), what only each side holds.
  defp differences(same, same), do: []

  defp differences({:ok, %{findings: _} = a}, {:ok, %{findings: _} = b}) do
    for part <- [:findings, :ran, :degraded, :extraction_errors],
        x = Enum.to_list(Map.fetch!(a, part)),
        y = Enum.to_list(Map.fetch!(b, part)),
        x != y,
        do: {part, only_batch: x -- y, only_graph: y -- x}
  end

  defp differences({:ok, %{} = a}, {:ok, %{} = b}) do
    for relation <- Enum.uniq(Map.keys(a) ++ Map.keys(b)) |> Enum.sort(),
        x = Map.get(a, relation, []),
        y = Map.get(b, relation, []),
        x != y,
        do: {relation, only_batch: x -- y, only_graph: y -- x}
  end

  defp differences(a, b), do: [batch: a, graph: b]

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
        findings = Enum.map(located, &(&1 |> Located.refine() |> Located.to_finding()))

        ran =
          {:ran, %{analysis: name, duration_ms: duration_ms, finding_count: length(findings)},
           findings}

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

  defp materialize(db, analyses, opts) do
    extracted = Argus.Schema.names() -- Argus.Schema.in_process_only()
    relations = for r <- extracted, do: {r, Graph.Relations.relation(db, {@program, r})}

    with {:ok, work} <- work_dir(),
         dir = Path.join(work, "facts"),
         :ok <- File.mkdir_p(dir),
         {:ok, files} <- Graph.Relations.files(db, @program, relations),
         :ok <- link_all(db, files, dir),
         :ok <- empty_files(Argus.Schema.in_process_only(), dir),
         :ok <- stage(db, :stage0, dir),
         :ok <- points_to(db, analyses, dir, opts) do
      {:ok, dir}
    end
  end

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
