defmodule Argus.Findings.Runner do
  @moduledoc """
  Runs a selection of analyses and collects their findings: the body of
  `Argus.Findings.run/2`.

  The selection resolves to modules (`Argus.Analysis.Sets.resolve/1`),
  the modules' facts are extracted once (`Argus.Analysis.extract_facts/3`,
  unless the caller hands in a `:facts_dir`), each analysis is solved in
  its own Souffle process, at most `:concurrency` at a time, and its rows
  are built into findings (`Argus.Findings.Build`). What did not go as
  planned becomes a `degraded` or `extraction_errors` entry of the
  result, per the contract in `Argus.Findings`' moduledoc.
  """

  alias Argus.Analysis
  alias Argus.Analysis.Sets
  alias Argus.Cache.Facts
  alias Argus.Findings
  alias Argus.Findings.Anchor
  alias Argus.Findings.Build
  alias Argus.Findings.Degradation
  alias Argus.Souffle

  @severity_rank %{error: 0, warning: 1, info: 2}

  @doc "See `Argus.Findings.run/2`."
  @spec run(modules :: [atom() | String.t()], keyword()) ::
          {:ok, Findings.t()} | {:error, term()}
  def run(modules, opts) when is_list(modules) and is_list(opts) do
    {selection, opts} = Keyword.pop(opts, :analyses, :all)

    with {:ok, requests} <- Sets.resolve(selection),
         :ok <- ensure_souffle(opts) do
      evaluate(modules, requests, opts)
    end
  end

  @doc """
  The extraction errors recorded in a facts directory
  (`Argus.Analysis.extract_facts/3` writes them as `extraction_error`):
  the base steps' first, then each extractor's in turn, each in module
  order (`Argus.Pipeline`'s producers).

  Every extraction writes `extraction_error.facts`, empty when nothing
  failed (`Argus.Pipeline.run/3` leaves a file for every schema
  relation). A directory without it is not an extraction's, or was
  changed under this read, and raises `Argus.MissingRelationError`:
  taken for none, it would drop the note that a module's findings are
  missing because it could not be read.
  """
  @spec extraction_errors(Path.t()) :: [Findings.extraction_error()]
  def extraction_errors(facts_dir) do
    case read_extraction_errors(facts_dir) do
      {:ok, errors} -> errors
      {:error, error} -> raise error
    end
  end

  defp read_extraction_errors(facts_dir) do
    path = Path.join(facts_dir, "extraction_error.facts")

    case File.read(path) do
      {:ok, content} ->
        {:ok, parse_extraction_errors(content)}

      {:error, reason} ->
        {:error,
         %Argus.MissingRelationError{relation: "extraction_error", path: path, reason: reason}}
    end
  end

  @doc false
  # The errors an `extraction_error.facts` file's content holds.
  @spec parse_extraction_errors(binary()) :: [Findings.extraction_error()]
  def parse_extraction_errors(content) do
    for [mod, step, reason] <- Argus.Tsv.decode(content) do
      %{module: Anchor.module_atom(mod), source: mod, step: step, reason: reason}
    end
  end

  defp evaluate(_modules, [], _opts), do: {:ok, %Findings{}}

  defp evaluate(modules, requests, opts) do
    names = Enum.map(requests, & &1.name())

    case facts(modules, names, opts) do
      {:ok, source} ->
        {points_to, source} = stage_points_to(source, names, opts)
        source = prepare(source, requests, points_to, opts)

        try do
          outcomes =
            requests
            |> Task.async_stream(&run_one(&1, source, points_to, opts),
              max_concurrency: Keyword.get(opts, :concurrency, default_solve_concurrency()),
              ordered: true,
              # Souffle.run bounds each evaluation with :souffle_timeout, so the
              # task itself never needs a second, racing deadline.
              timeout: :infinity
            )
            |> Enum.flat_map(fn {:ok, outcomes} -> outcomes end)

          with {:ok, errors} <- source_errors(source) do
            {:ok, %{collect(outcomes) | extraction_errors: errors}}
          end
        after
          release(source)
        end

      # Stage 0 (the shared call graph) is a Souffle evaluation like any
      # other, and Souffle trouble is degradation, not a crash — the same
      # contract a per-analysis solve gets. Because every analysis reads
      # its output, a stage-0 failure grounds all of them, so each one
      # degrades with the underlying reason rather than the whole call
      # collapsing into an opaque error.
      {:error, {:stage0, reason}} ->
        {:ok,
         collect(
           for mod <- requests, name = mod.name() do
             {:degraded,
              %{analysis: name, reason: reason, detail: Degradation.detail(name, reason)}}
           end
         )}

      {:error, _reason} = error ->
        error
    end
  end

  # Where the facts are: `{:dir, dir, owned?}`, a directory the caller
  # handed in or the run extracted, or `{:cached, facts}`, through the
  # store `cache:` names (`Argus.Cache.Facts`). The points-to stage is
  # staged once, by `evaluate/3`, before the solves fan out: each would
  # otherwise find it missing and derive it into the same directory at
  # once.
  defp facts(modules, names, opts) do
    case Keyword.fetch(opts, :facts_dir) do
      {:ok, dir} ->
        {:ok, {:dir, dir, false}}

      :error ->
        opts = Keyword.put(opts, :points_to, :deferred)

        case Analysis.Extraction.cached_facts(modules, names, opts) do
          {:ok, facts} ->
            {:ok, {:cached, facts}}

          :uncached ->
            with {:ok, dir} <- Analysis.extract_facts(modules, names, opts),
                 do: {:ok, {:dir, dir, true}}

          {:error, _} = error ->
            error
        end
    end
  end

  defp stage_points_to({:dir, dir, _owned?} = source, names, opts),
    do: {Analysis.Extraction.ensure_points_to(dir, names, opts), source}

  defp stage_points_to({:cached, facts} = source, names, opts) do
    programs = [programs: Argus.Cache.dir(facts.store, :programs)]

    if Enum.any?(names, &Analysis.Extraction.reads_points_to?(&1, programs)) do
      case Analysis.Extraction.solve_points_to(facts, opts) do
        {:ok, facts} -> {:ok, {:cached, facts}}
        {:error, _} = error -> {error, source}
      end
    else
      {:ok, source}
    end
  end

  # Facts through a store get a directory before the solves fan out,
  # holding what the solves that are not kept read, so they share it
  # and none places a file while another reads.
  defp prepare({:cached, facts} = source, requests, points_to, opts) do
    rules =
      for mod <- requests,
          points_to == :ok or not Analysis.Extraction.reads_points_to?(mod.name()),
          {:ok, path} <- [Analysis.Catalog.rules_path(mod.name())],
          do: path

    case Facts.prepare(facts, rules, opts) do
      {:ok, facts} -> {:cached, facts}
      {:error, _} -> source
    end
  end

  defp prepare(source, _requests, _points_to, _opts), do: source

  defp solve(name, {:dir, dir, _owned?}, opts), do: Analysis.run_rules(dir, name, opts)

  # A solve that made a directory of its own (it missed where the
  # others were kept) removes it.
  defp solve(name, {:cached, facts}, opts) do
    with {:ok, rules} <- Analysis.Catalog.rules_path(name),
         {:ok, results, solved} <- Facts.solve(facts, rules, opts) do
      if solved.work != facts.work, do: Facts.release(solved)
      {:ok, results}
    end
  end

  defp source_errors({:dir, dir, _owned?}), do: read_extraction_errors(dir)

  defp source_errors({:cached, facts}),
    do: {:ok, facts |> Facts.extraction_errors() |> parse_extraction_errors()}

  defp release({:dir, dir, true}), do: File.rm_rf(Path.dirname(dir))
  defp release({:dir, _dir, false}), do: :ok
  defp release({:cached, facts}), do: Facts.release(facts)

  # A failed points-to stage grounds only the analyses that read it;
  # the rest solve as usual.
  defp run_one(mod, source, {:error, reason}, opts) do
    name = mod.name()

    if Analysis.Extraction.reads_points_to?(name) do
      [{:degraded, %{analysis: name, reason: reason, detail: Degradation.detail(name, reason)}}]
    else
      run_one(mod, source, :ok, opts)
    end
  end

  # One solve per analysis module; every row is a finding under the
  # analysis's own name.
  defp run_one(mod, source, :ok, opts) do
    name = mod.name()
    {elapsed_us, result} = :timer.tc(fn -> solve(name, source, opts) end)
    duration_ms = div(elapsed_us, 1000)

    case result do
      {:ok, results} ->
        try do
          {findings, failures} = Build.build(mod, results)

          ran =
            {:ran, %{analysis: name, duration_ms: duration_ms, finding_count: length(findings)},
             findings}

          [ran | Degradation.rows(name, failures)]
        rescue
          exception ->
            [
              {:degraded,
               %{
                 analysis: name,
                 reason: {:finding_builder_crashed, exception},
                 detail:
                   "The #{name} analysis ran, but converting its results to findings " <>
                     "crashed: #{Exception.message(exception)}. This is a bug in Argus."
               }}
            ]
        end

      {:error, reason} ->
        [{:degraded, %{analysis: name, reason: reason, detail: Degradation.detail(name, reason)}}]
    end
  end

  # Each solve is a Souffle process holding its own copy of the call
  # graph's closure — hundreds of megabytes on a large project, and it
  # scales with the project rather than the machine. Extraction is cheap
  # per task and runs at scheduler width; solves are capped so the peak
  # stays bounded.
  defp default_solve_concurrency, do: min(System.schedulers_online(), 4)

  defp collect(outcomes) do
    findings =
      outcomes
      |> Enum.flat_map(fn
        {:ran, _entry, findings} -> Enum.map(findings, &unplaced/1)
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

  # The batch backend places no finding: its `file`, `line` and
  # `end_line` are nil, and each related frame's (the graph's are placed,
  # `Argus.Located`).
  @nowhere %{file: nil, line: nil, end_line: nil}

  defp unplaced(finding) do
    finding
    |> Map.merge(@nowhere)
    |> Map.update(:related, [], fn frames -> Enum.map(frames, &Map.merge(&1, @nowhere)) end)
  end

  defp ensure_souffle(opts) do
    cond do
      # An explicit binary is the caller's responsibility; Souffle.run
      # reports per-analysis errors if it turns out to be unusable.
      Keyword.has_key?(opts, :souffle_bin) -> :ok
      Souffle.available?() -> :ok
      true -> {:error, :souffle_not_found}
    end
  end
end
