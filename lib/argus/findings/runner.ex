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
  alias Argus.Findings
  alias Argus.Findings.Anchor
  alias Argus.Findings.Build
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
  (`Argus.Analysis.extract_facts/3` writes them as `extraction_error`),
  in the order extraction met them. A directory without the file has
  none.
  """
  @spec extraction_errors(Path.t()) :: [Findings.extraction_error()]
  def extraction_errors(facts_dir) do
    case File.read(Path.join(facts_dir, "extraction_error.facts")) do
      {:ok, content} ->
        for [mod, step, reason] <- Argus.Tsv.decode(content) do
          %{module: Anchor.module_atom(mod), source: mod, step: step, reason: reason}
        end

      {:error, _} ->
        []
    end
  end

  defp evaluate(_modules, [], _opts), do: {:ok, %Findings{}}

  defp evaluate(modules, requests, opts) do
    names = Enum.map(requests, & &1.name())

    case facts_dir(modules, names, opts) do
      {:ok, facts_dir, owned?} ->
        try do
          outcomes =
            requests
            |> Task.async_stream(&run_one(&1, facts_dir, opts),
              max_concurrency: Keyword.get(opts, :concurrency, default_solve_concurrency()),
              ordered: true,
              # Souffle.run bounds each evaluation with :souffle_timeout, so the
              # task itself never needs a second, racing deadline.
              timeout: :infinity
            )
            |> Enum.flat_map(fn {:ok, outcomes} -> outcomes end)

          {:ok, %{collect(outcomes) | extraction_errors: extraction_errors(facts_dir)}}
        after
          if owned?, do: File.rm_rf(Path.dirname(facts_dir))
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
              %{analysis: name, reason: reason, detail: degradation_detail(name, reason)}}
           end
         )}

      {:error, _reason} = error ->
        error
    end
  end

  defp facts_dir(modules, names, opts) do
    case Keyword.fetch(opts, :facts_dir) do
      {:ok, dir} ->
        {:ok, dir, false}

      :error ->
        with {:ok, dir} <- Analysis.extract_facts(modules, names, opts), do: {:ok, dir, true}
    end
  end

  # One solve per analysis module; every row is a finding under the
  # analysis's own name.
  defp run_one(mod, facts_dir, opts) do
    name = mod.name()
    {elapsed_us, result} = :timer.tc(fn -> Analysis.run_rules(facts_dir, name, opts) end)
    duration_ms = div(elapsed_us, 1000)

    case result do
      {:ok, results} ->
        try do
          {findings, failures} = Build.build(mod, results)

          ran =
            {:ran, %{analysis: name, duration_ms: duration_ms, finding_count: length(findings)},
             findings}

          [ran | row_degradation(name, failures)]
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
        [{:degraded, %{analysis: name, reason: reason, detail: degradation_detail(name, reason)}}]
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

  defp row_degradation(_name, []), do: []

  defp row_degradation(name, [first | _] = failures) do
    [
      {:degraded,
       %{
         analysis: name,
         reason: {:finding_builder_crashed, first.exception},
         detail:
           "The #{name} analysis ran, but its finding builder crashed on " <>
             "#{length(failures)} row(s), first a #{first.relation} row: " <>
             "#{Exception.message(first.exception)}. Those rows are reported with " <>
             "their raw columns; every other finding is as usual. This is a bug in Argus."
       }}
    ]
  end

  defp degradation_detail(name, :souffle_timeout) do
    "The #{name} analysis timed out in Souffle and was skipped. " <>
      "Raise :souffle_timeout to include it."
  end

  defp degradation_detail(name, {:souffle_error, exit_code, _output}) do
    "The #{name} analysis failed: Souffle exited with status #{exit_code}."
  end

  defp degradation_detail(name, reason) do
    "The #{name} analysis did not run: #{inspect(reason)}."
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
