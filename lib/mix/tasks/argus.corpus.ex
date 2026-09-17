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
  changes: which titles fire, how often, and on what.
  """

  use Mix.Task

  alias Argus.Corpus

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.config")

    case args do
      ["fetch" | _] -> fetch()
      ["tally" | rest] -> tally(rest)
      _ -> Mix.raise("usage: mix argus.corpus fetch | tally [--title SUBSTRING]")
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
      for pair <- Corpus.pairs(),
          side <- [:pre, :fix],
          co = Corpus.checkout(pair, side),
          co != nil,
          {:ok, beams} <- [Corpus.ensure(pair, side)],
          {:ok, results} <- [Corpus.analyze(beams)],
          finding <- results.findings,
          filter == nil or String.contains?(finding.title, filter),
          do: {finding.analysis, finding.title, co.name, finding.mfa}

    if filter do
      Enum.each(rows, fn {a, t, name, mfa} ->
        Mix.shell().info("#{name}  #{a}  #{inspect(mfa)}  #{t}")
      end)
    else
      rows
      |> Enum.frequencies_by(fn {a, t, _, _} -> {a, t} end)
      |> Enum.sort_by(fn {_, n} -> -n end)
      |> Enum.each(fn {{a, t}, n} ->
        Mix.shell().info(
          String.pad_leading(to_string(n), 5) <>
            "  " <> String.pad_trailing(to_string(a), 26) <> t
        )
      end)
    end

    :ok
  end
end
