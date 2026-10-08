defmodule Mix.Tasks.Argus.Corpus do
  @shortdoc "Fetches the closed-issue corpus and tallies findings across it"

  @moduledoc """
  Maintainer tooling over `Argus.Corpus`, the checkouts the test suite
  verifies rules against.

      mix argus.corpus fetch          # clone and compile every pair, ahead of a test run
      mix argus.corpus tally          # every finding title, counted across all checkouts
      mix argus.corpus tally --title "owner may be restarting"   # the rows behind one title
      mix argus.corpus diff           # every finding moved since the baseline, by title
      mix argus.corpus accept         # take the findings as they are now as the baseline

  `fetch` is what `Argus.CorpusTest` does lazily; running it first keeps
  the test run itself short. A pair this machine cannot build (a
  toolchain it has no asdf install of, a repository that cannot be
  fetched) is reported skipped, with the reason (`Argus.Corpus`, "What
  a machine cannot check"). `tally` is the noise check after a rule
  changes: which titles fire, how often, and on what. It analyzes each
  checkout once, `ARGUS_CORPUS_JOBS` at a time (`Argus.Corpus.jobs/0`),
  and its output does not depend on which finishes first.

  `diff` is the same check made exact: every finding added or removed
  since each checkout's baseline (`Argus.Corpus.Baseline`), the one the
  first run recorded or `accept` last took. The corpus test says the
  same in brief after each run. Take a baseline before changing a rule,
  and `diff` after says what the change did to every tree, not only to
  the pairs it was written for; `accept` once those moves are the
  intended ones. `ARGUS_CORPUS_ONLY` narrows all three to some pairs'
  checkouts.

  Every checkout's graph is kept in its manifest, over the shared blob
  store (`Argus.Corpus.manifest/1`); `argus gc` collects the store (the
  former `prune`), and every driver run collects it once a day.
  """

  use Mix.Task

  @usage "usage: mix argus.corpus fetch | tally [--title SUBSTRING] | diff | accept"

  alias Argus.Corpus
  alias Argus.Corpus.Baseline

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.config")

    case args do
      ["fetch" | _] ->
        fetch()

      ["tally" | rest] ->
        tally(rest)

      ["diff"] ->
        diff()

      ["accept"] ->
        accept()

      ["prune" | _rest] ->
        Mix.raise("mix argus.corpus prune is gone: `argus gc` collects the blob store")

      _ ->
        Mix.raise(@usage)
    end
  end

  defp fetch do
    for pair <- Corpus.selected(), side <- [:pre, :fix], Corpus.checkout(pair, side) do
      co = Corpus.checkout(pair, side)

      case Corpus.ensure(pair, side) do
        {:ok, beams} -> Mix.shell().info("#{co.name}: #{length(beams)} beams")
        {:skip, why} -> Mix.shell().info("#{co.name}: skipped, #{why}")
        {:error, why} -> Mix.shell().error("#{co.name}: #{why}")
      end
    end

    :ok
  end

  defp diff do
    changed =
      for {co, entries, degraded} <- analyzed_entries(),
          changes = Baseline.compare(co, entries, degraded),
          moved?(co, changes),
          do: {co, changes}

    case Baseline.report(changed, rows: true) do
      [] -> Mix.shell().info("argus: no finding moved since the baseline")
      lines -> Enum.each(lines, &Mix.shell().info(&1))
    end
  end

  defp moved?(co, {:recorded, count}) do
    Mix.shell().info("#{co.name}: no baseline; recorded its #{count} finding(s) as one")
    false
  end

  defp moved?(co, {:unrecorded, degraded}) do
    Mix.shell().error("#{co.name}: no baseline, and #{inspect(degraded)} degraded; none recorded")
    false
  end

  defp moved?(_co, %{added: added, removed: removed}), do: added != [] or removed != []

  # A run in which an analysis degraded reported nothing for it: taking
  # it would record its findings as gone.
  defp accept do
    accepted = for {co, entries, []} <- analyzed_entries(), do: {co, entries}
    Enum.each(accepted, fn {co, entries} -> Baseline.write!(co, entries) end)
    Mix.shell().info("argus: took #{length(accepted)} checkout(s)' findings as the baseline")
  end

  # Each selected checkout's entries, and the analyses that degraded in
  # its run, said here (`Baseline.compare/3` leaves them out); one that
  # cannot be analyzed is said and left out, its baseline untouched.
  defp analyzed_entries do
    Corpus.selected()
    |> Corpus.checkouts()
    |> Corpus.analyze_all(fn
      {:ok, results} -> {:ok, Map.take(results, [:findings, :degraded])}
      other -> other
    end)
    |> Enum.flat_map(fn
      {co, {:ok, results}} ->
        degraded = Baseline.degraded(results)

        if degraded != [] do
          Mix.shell().error(
            "#{co.name}: #{inspect(degraded)} degraded; their findings are not compared"
          )
        end

        [{co, Baseline.entries(co, results), degraded}]

      {co, {:skip, why}} ->
        Mix.shell().info("#{co.name}: skipped, #{why}")
        []

      {co, {:error, why}} ->
        Mix.shell().error("#{co.name}: #{format_error(why)}")
        []
    end)
  end

  defp tally(args) do
    {opts, _, _} = OptionParser.parse(args, strict: [title: :string])
    filter = Keyword.get(opts, :title)

    rows =
      Corpus.selected()
      |> Corpus.checkouts()
      |> Corpus.analyze_all(&rows(&1, filter))
      |> Enum.flat_map(fn
        {co, {:ok, rows}} ->
          for {a, t, mfa} <- rows, do: {a, t, co.name, mfa}

        {co, {:skip, why}} ->
          Mix.shell().info("#{co.name}: skipped, #{why}")
          []

        {co, {:error, why}} ->
          Mix.shell().error("#{co.name}: #{format_error(why)}")
          []
      end)

    if filter do
      Enum.each(rows, fn {a, t, name, mfa} ->
        Mix.shell().info("#{name}  #{a}  #{inspect(mfa)}  #{t}")
      end)
    else
      rows
      |> Enum.frequencies_by(fn {a, t, _, _} -> {a, t} end)
      |> Enum.sort_by(fn {{a, t}, n} -> {-n, a, t} end)
      |> Enum.each(fn {{a, t}, n} ->
        Mix.shell().info(
          String.pad_leading(to_string(n), 5) <>
            "  " <> String.pad_trailing(to_string(a), 26) <> t
        )
      end)
    end

    :ok
  end

  # Only the columns the tally prints leave the analyzing task.
  defp rows({:ok, results}, filter) do
    rows =
      for finding <- results.findings,
          filter == nil or String.contains?(finding.title, filter),
          do: {finding.analysis, finding.title, finding.mfa}

    {:ok, rows}
  end

  defp rows(failed, _filter), do: failed

  defp format_error(why) when is_binary(why), do: why
  defp format_error(why), do: inspect(why)
end
