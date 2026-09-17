defmodule Argus.CorpusTest do
  @moduledoc """
  The closed-issue corpus, as a test: for every pair in
  `test/corpus/pairs.exs`, the finding is present on the pre-fix tree and
  absent on the fix.

  The first run clones and compiles each tree into `ARGUS_CORPUS_DIR`
  (default `~/.cache/argus/corpus`); later runs only analyze. Narrow a
  run with `ARGUS_CORPUS_ONLY=redix#334,oban` (substrings of the issue
  name), or leave the corpus out with `mix test --exclude corpus`.
  """

  use ExUnit.Case, async: false

  alias Argus.Corpus

  @moduletag :corpus
  @moduletag timeout: :infinity

  @only (case System.get_env("ARGUS_CORPUS_ONLY") do
           nil -> nil
           s -> s |> String.split(",", trim: true) |> Enum.map(&String.trim/1)
         end)

  # The error names the step (clone, deps.get, compile) and carries the
  # tail of its output; a pattern-match failure would truncate it.
  defp ensure!(pair, side) do
    case Corpus.ensure(pair, side) do
      {:ok, beams} -> beams
      {:error, why} -> flunk("#{pair.issue} #{side}: #{why}")
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
    selected? = @only == nil or Enum.any?(@only, &String.contains?(pair.issue, &1))

    @tag skip: if(selected?, do: false, else: "not in ARGUS_CORPUS_ONLY")
    test "#{pair.issue}: #{analysis} / #{title} — #{sides}" do
      skip_without_souffle()
      pair = @pair
      {analysis, title} = pair.finding
      _ = {analysis, title}

      beams = ensure!(pair, :pre)
      assert {:ok, results} = Corpus.analyze(beams)

      assert results.degraded == [],
             "degraded analyses on #{pair.issue} pre: #{inspect(results.degraded)}"

      assert Corpus.present?(results, pair),
             "#{pair.issue}: #{analysis} / #{title}#{in_module(pair)} not found on the pre-fix tree; seen:\n" <>
               Enum.map_join(results.findings, "\n", fn f ->
                 "  #{f.analysis}: #{f.title} (#{inspect(f.module)})"
               end)

      if Map.has_key?(pair, :fix) do
        beams = ensure!(pair, :fix)
        assert {:ok, results} = Corpus.analyze(beams)

        refute Corpus.present?(results, pair),
               "#{pair.issue}: #{analysis} / #{title}#{in_module(pair)} still reported on the fix"
      end
    end
  end
end
