defmodule Argus.CorpusTest do
  @moduledoc """
  The closed-issue corpus, as a test: for every pair in
  `test/corpus/pairs.exs`, the finding is present on the pre-fix tree and
  absent on the fix.

  The first run clones and compiles each tree into `ARGUS_CORPUS_DIR`
  (default `~/.cache/argus/corpus`) and caches its facts beside it; later
  runs only solve. Every checkout the selected pairs need is analyzed
  once, up to `ARGUS_CORPUS_JOBS` at a time (default 4, at most the
  scheduler count), before the pairs are checked. Narrow a run with
  `ARGUS_CORPUS_ONLY=redix#334,oban` (substrings of the issue name), or
  leave the corpus out with `mix test --exclude corpus`.
  """

  use ExUnit.Case, async: true

  alias Argus.Corpus

  @moduletag :corpus
  @moduletag timeout: :infinity

  @only (case System.get_env("ARGUS_CORPUS_ONLY") do
           nil -> nil
           s -> s |> String.split(",", trim: true) |> Enum.map(&String.trim/1)
         end)

  @jobs (case System.get_env("ARGUS_CORPUS_JOBS") do
           nil -> min(4, System.schedulers_online())
           s -> String.to_integer(s)
         end)

  @selected Enum.filter(Corpus.pairs(), fn pair ->
              @only == nil or Enum.any?(@only, &String.contains?(pair.issue, &1))
            end)

  # One analysis per checkout, however many pairs share it, at @jobs
  # abreast: each is extraction at scheduler width on a cold cache and
  # four solves on a warm one. Only what the tests read is kept — the
  # findings of a large tree are megabytes of prose that would otherwise
  # be copied into every test's context.
  setup_all do
    if Argus.Souffle.available?() do
      results =
        for(
          pair <- @selected,
          side <- [:pre, :fix],
          co = Corpus.checkout(pair, side),
          co != nil,
          do: {co.name, pair, side}
        )
        |> Enum.uniq_by(fn {name, _pair, _side} -> name end)
        |> Task.async_stream(
          fn {name, pair, side} -> {name, slim(Corpus.analyze(pair, side))} end,
          max_concurrency: @jobs,
          ordered: false,
          timeout: :infinity
        )
        |> Map.new(fn {:ok, entry} -> entry end)

      %{results: results}
    else
      %{results: %{}}
    end
  end

  defp slim({:ok, %{findings: findings, degraded: degraded}}) do
    {:ok,
     %{
       degraded: degraded,
       findings: Enum.map(findings, &Map.take(&1, [:analysis, :title, :module]))
     }}
  end

  defp slim({:error, _} = error), do: error

  # The error names the step (clone, deps.get, compile) and carries the
  # tail of its output; a pattern-match failure would truncate it.
  defp results!(results, pair, side) do
    %{name: name} = Corpus.checkout(pair, side)

    case Map.fetch(results, name) do
      {:ok, {:ok, findings}} -> findings
      {:ok, {:error, why}} -> flunk("#{pair.issue} #{side}: #{why}")
      :error -> flunk("#{pair.issue} #{side}: #{name} was not analyzed")
    end
  end

  defp in_module(%{module: module}), do: " in #{module}"
  defp in_module(_pair), do: ""

  defp skip_without_souffle do
    unless Argus.Souffle.available?(), do: flunk("souffle not installed")
  end

  for pair <- Corpus.pairs() do
    {analysis, title} = pair.finding

    sides =
      if Map.has_key?(pair, :fix), do: "present at pre, absent at fix", else: "present at pre"

    @pair pair
    selected? = pair in @selected

    @tag skip: if(selected?, do: false, else: "not in ARGUS_CORPUS_ONLY")
    test "#{pair.issue}: #{analysis} / #{title} — #{sides}", %{results: results} do
      skip_without_souffle()
      pair = @pair
      {analysis, title} = pair.finding
      _ = {analysis, title}

      pre = results!(results, pair, :pre)

      assert pre.degraded == [],
             "degraded analyses on #{pair.issue} pre: #{inspect(pre.degraded)}"

      assert Corpus.present?(pre, pair),
             "#{pair.issue}: #{analysis} / #{title}#{in_module(pair)} not found on the pre-fix tree; seen:\n" <>
               Enum.map_join(pre.findings, "\n", fn f ->
                 "  #{f.analysis}: #{f.title} (#{inspect(f.module)})"
               end)

      if Map.has_key?(pair, :fix) do
        fix = results!(results, pair, :fix)

        refute Corpus.present?(fix, pair),
               "#{pair.issue}: #{analysis} / #{title}#{in_module(pair)} still reported on the fix"
      end
    end
  end
end
