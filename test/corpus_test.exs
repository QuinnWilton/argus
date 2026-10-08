defmodule Argus.CorpusTest do
  @moduledoc """
  The closed-issue corpus, as a test: for every pair in
  `test/corpus/pairs.exs`, the finding is present on the pre-fix tree and
  absent on the fix.

  The first run clones and compiles each tree into `ARGUS_CORPUS_DIR`
  (default `~/.cache/argus/corpus`) and keeps its graph in a manifest
  beside it (`Argus.Corpus.manifest/1`), over the shared blob store; a
  later run extracts and solves only what an edit invalidated. Every checkout the selected pairs need is analyzed
  once, up to `ARGUS_CORPUS_JOBS` at a time (default 4, at most the
  scheduler count), before the pairs are checked. Narrow a run with
  `ARGUS_CORPUS_ONLY=redix#334,oban` (substrings of the issue name). Plain
  `mix test` leaves the corpus out; `mix test --only corpus` runs it. A pair this
  machine cannot check is skipped, with the reason: a tree not compiled
  here needs an Erlang or Elixir with no asdf install
  (`Argus.Corpus.unbuildable/1`), or a tree not checked out here comes
  from a repository that cannot be fetched (`Argus.Corpus.unfetchable/1`,
  asked of the network only when the corpus runs).
  """

  use ExUnit.Case, async: true

  alias Argus.Corpus
  alias Argus.Corpus.Baseline

  @moduletag :corpus
  @moduletag :flowlog
  @moduletag timeout: :infinity

  @only Corpus.only()

  # Whether this run checks the corpus at all: its repositories are asked
  # whether they can be fetched only then.
  @runs (
          config = ExUnit.configuration()

          ExUnit.Filters.eval(config[:include], config[:exclude], %{corpus: true, test: true}, []) ==
            :ok
        )

  # Why each pair is not checked here, by its issue, or false. The
  # repositories are asked side by side.
  @skipped Corpus.pairs()
           |> Task.async_stream(
             fn pair ->
               reason =
                 cond do
                   @only != nil and not Enum.any?(@only, &String.contains?(pair.issue, &1)) ->
                     "not in ARGUS_CORPUS_ONLY"

                   reason = Corpus.unbuildable(pair) ->
                     reason

                   reason = @runs && Corpus.unfetchable(pair) ->
                     reason

                   true ->
                     false
                 end

               {pair.issue, reason}
             end,
             max_concurrency: 8,
             timeout: :infinity
           )
           |> Map.new(fn {:ok, skipped} -> skipped end)

  @selected Enum.filter(Corpus.pairs(), &(Map.fetch!(@skipped, &1.issue) == false))

  # One analysis per checkout, however many pairs share it, through
  # `Corpus.analyze_all/2`. Only what the tests read is kept — the
  # findings of a large tree are megabytes of prose that would otherwise
  # be copied into every test's context.
  setup_all do
    # ExUnit reports a skip without its reason: the ones this machine
    # decided are said once, before the pairs run.
    unchecked =
      for {_issue, reason} <- Enum.sort(@skipped),
          reason not in [false, "not in ARGUS_CORPUS_ONLY"],
          do: "  #{reason}"

    if unchecked != [] do
      IO.puts(
        :stderr,
        "\nCorpus pairs this machine cannot check (skipped):\n" <> Enum.join(unchecked, "\n")
      )
    end

    analyzed =
      @selected
      |> Corpus.checkouts()
      |> Corpus.analyze_all(&slim/1)

    say_changes(analyzed)
    %{results: Map.new(analyzed, fn {co, result} -> {co.name, result} end)}
  end

  # What a rule's own pairs cannot say: every other finding the run moved
  # since the checkouts' baselines (`Argus.Corpus.Baseline`). Said, not
  # asserted: a change is meant to move findings, and its author decides
  # which moves are right.
  defp say_changes(analyzed) do
    changed =
      for {co, {:ok, results}} <- analyzed,
          entries = Baseline.entries(co, results),
          %{added: added, removed: removed} = changes <- [Baseline.compare(co, entries)],
          added != [] or removed != [],
          do: {co, changes}

    if changed != [] do
      IO.puts(
        :stderr,
        "\nCorpus findings moved since the baseline, in #{length(changed)} checkout(s) " <>
          "(`mix argus.corpus diff` lists them; `mix argus.corpus accept` takes them):\n" <>
          Enum.map_join(Baseline.report(changed), "\n", &("  " <> &1))
      )
    end
  end

  # What a baseline compares is kept too (`Argus.Corpus.Baseline.entries/2`).
  defp slim({:ok, %{findings: findings, degraded: degraded, extraction_errors: errors}}) do
    {:ok,
     %{
       degraded: degraded,
       extraction_errors: errors,
       findings: Enum.map(findings, &Map.take(&1, Baseline.fields()))
     }}
  end

  defp slim({:error, _} = error), do: error
  defp slim({:skip, _} = skip), do: skip

  # The error names the step (clone, deps.get, compile) and carries the
  # tail of its output; a pattern-match failure would truncate it.
  defp results!(results, pair, side) do
    %{name: name} = Corpus.checkout(pair, side)

    case Map.fetch(results, name) do
      {:ok, {:ok, findings}} -> findings
      {:ok, {:error, why}} -> flunk("#{pair.issue} #{side}: #{why}")
      # Unchecked when the test was compiled, and no longer checkable.
      {:ok, {:skip, why}} -> flunk("#{pair.issue} #{side}: #{why}")
      :error -> flunk("#{pair.issue} #{side}: #{name} was not analyzed")
    end
  end

  defp in_module(%{module: module, function: {name, arity}}),
    do: " in #{module}.#{name}/#{arity}"

  defp in_module(%{module: module}), do: " in #{module}"
  defp in_module(_pair), do: ""

  for pair <- Corpus.pairs() do
    {analysis, title} = pair.finding

    sides =
      if Map.has_key?(pair, :fix), do: "present at pre, absent at fix", else: "present at pre"

    @pair pair

    @tag skip: Map.fetch!(@skipped, pair.issue)
    test "#{pair.issue}: #{analysis} / #{title} — #{sides}", %{results: results} do
      pair = @pair
      {analysis, title} = pair.finding
      _ = {analysis, title}

      pre = results!(results, pair, :pre)

      assert pre.degraded == [],
             "degraded analyses on #{pair.issue} pre: #{inspect(pre.degraded)}"

      assert pre.extraction_errors == [],
             "extraction errors on #{pair.issue} pre: #{inspect(pre.extraction_errors)}"

      assert Corpus.present?(pre, pair),
             "#{pair.issue}: #{analysis} / #{title}#{in_module(pair)} not found on the pre-fix tree; seen:\n" <>
               Enum.map_join(pre.findings, "\n", fn f ->
                 "  #{f.analysis}: #{f.title} (#{inspect(f.module)})"
               end)

      if Map.has_key?(pair, :fix) do
        fix = results!(results, pair, :fix)

        assert fix.degraded == [],
               "degraded analyses on #{pair.issue} fix: #{inspect(fix.degraded)}"

        assert fix.extraction_errors == [],
               "extraction errors on #{pair.issue} fix: #{inspect(fix.extraction_errors)}"

        refute Corpus.present?(fix, pair),
               "#{pair.issue}: #{analysis} / #{title}#{in_module(pair)} still reported on the fix"
      end
    end
  end
end
