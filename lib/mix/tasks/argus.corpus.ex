defmodule Mix.Tasks.Argus.Corpus do
  @shortdoc "Fetches the closed-issue corpus and tallies findings across it"

  @moduledoc """
  Maintainer tooling over `Argus.Corpus`, the checkouts the test suite
  verifies rules against.

      mix argus.corpus fetch          # clone and compile every pair, ahead of a test run
      mix argus.corpus tally          # every finding title, counted across all checkouts
      mix argus.corpus tally --title "owner may be restarting"   # the rows behind one title

  `fetch` is what `Argus.CorpusTest` does lazily; running it first keeps
  the test run itself short. `tally` is the noise check after a rule
  changes: which titles fire, how often, and on what. It analyzes each
  checkout once, `ARGUS_CORPUS_JOBS` at a time (`Argus.Corpus.jobs/0`),
  and its output does not depend on which finishes first.

  Every checkout's graph is kept in its manifest, over the shared blob
  store (`Argus.Corpus.manifest/1`); `argus gc` collects the store (the
  former `prune`), and every driver run collects it once a day.
  """

  use Mix.Task

  @usage "usage: mix argus.corpus fetch | tally [--title SUBSTRING]"

  alias Argus.Corpus

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.config")

    case args do
      ["fetch" | _] ->
        fetch()

      ["tally" | rest] ->
        tally(rest)

      ["prune" | _rest] ->
        Mix.raise("mix argus.corpus prune is gone: `argus gc` collects the blob store")

      _ ->
        Mix.raise(@usage)
    end
  end

  defp fetch do
    for pair <- Corpus.pairs(), side <- [:pre, :fix], Corpus.checkout(pair, side) do
      co = Corpus.checkout(pair, side)

      case Corpus.ensure(pair, side) do
        {:ok, beams} -> Mix.shell().info("#{co.name}: #{length(beams)} beams")
        {:error, why} -> Mix.shell().error("#{co.name}: #{why}")
      end
    end

    :ok
  end

  defp tally(args) do
    {opts, _, _} = OptionParser.parse(args, strict: [title: :string])
    filter = Keyword.get(opts, :title)

    rows =
      Corpus.pairs()
      |> Corpus.checkouts()
      |> Corpus.analyze_all(&rows(&1, filter))
      |> Enum.flat_map(fn
        {co, {:ok, rows}} ->
          for {a, t, mfa} <- rows, do: {a, t, co.name, mfa}

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

  defp rows({:error, _} = error, _filter), do: error

  defp format_error(why) when is_binary(why), do: why
  defp format_error(why), do: inspect(why)
end
