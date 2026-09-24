defmodule Mix.Tasks.Argus.Corpus do
  @shortdoc "Fetches the closed-issue corpus and tallies findings across it"

  @moduledoc """
  Maintainer tooling over `Argus.Corpus`, the checkouts the test suite
  verifies rules against.

      mix argus.corpus fetch          # clone and compile every pair, ahead of a test run
      mix argus.corpus tally          # every finding title, counted across all checkouts
      mix argus.corpus tally --title "owner may be restarting"   # the rows behind one title
      mix argus.corpus prune          # drop facts no run has used lately
      mix argus.corpus prune --keep 0 --dry-run

  `fetch` is what `Argus.CorpusTest` does lazily; running it first keeps
  the test run itself short. `tally` is the noise check after a rule
  changes: which titles fire, how often, and on what. It analyzes each
  checkout once, `ARGUS_CORPUS_JOBS` at a time (`Argus.Corpus.jobs/0`),
  and its output does not depend on which finishes first.

  `prune` removes, from every checkout, the cached facts
  `Argus.Corpus.stale_facts/2` names: entries untouched for an hour
  beyond the `--keep` most recent (default 3), and staging directories
  a crashed run left a day ago. An entry touched within the hour is
  never removed — a run beside this one may be reading it. Within each
  entry that stays, the kept solves of each program go by the same
  policy (`Argus.Corpus.stale_solves/2`).
  """

  use Mix.Task

  @usage "usage: mix argus.corpus fetch | tally [--title SUBSTRING] | prune [--keep N] [--dry-run]"

  alias Argus.Corpus

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.config")

    case args do
      ["fetch" | _] -> fetch()
      ["tally" | rest] -> tally(rest)
      ["prune" | rest] -> prune(rest)
      _ -> Mix.raise(@usage)
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

  defp prune(args) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: [keep: :integer, dry_run: :boolean])
    if rest != [] or invalid != [], do: Mix.raise(@usage)

    policy =
      case Keyword.fetch(opts, :keep) do
        {:ok, keep} when keep >= 0 -> [recent: keep]
        {:ok, _negative} -> Mix.raise("--keep must be 0 or more")
        :error -> []
      end

    dry_run? = Keyword.get(opts, :dry_run, false)

    {count, bytes} =
      Enum.reduce(Corpus.facts_caches(), {0, 0}, fn cache, {count, bytes} ->
        stale_entries = Corpus.stale_facts(cache, policy)

        # The kept solves of the entries that stay; a removed entry takes
        # its own with it.
        stale_solves =
          for solves <- Corpus.solve_caches(cache),
              Path.dirname(solves) not in stale_entries,
              path <- Corpus.stale_solves(solves, policy),
              do: path

        stale = stale_entries ++ stale_solves
        size = stale |> Enum.map(&tree_bytes/1) |> Enum.sum()
        unless dry_run?, do: Enum.each(stale, &File.rm_rf!/1)
        {count + length(stale), bytes + size}
      end)

    verb = if dry_run?, do: "would remove", else: "removed"
    Mix.shell().info("#{verb} #{count} entries, #{format_bytes(bytes)}")
    :ok
  end

  defp tree_bytes(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} ->
        path |> File.ls!() |> Enum.map(&tree_bytes(Path.join(path, &1))) |> Enum.sum()

      {:ok, %File.Stat{size: size}} ->
        size

      {:error, _} ->
        0
    end
  end

  defp format_bytes(bytes) when bytes >= 1024 * 1024 * 1024,
    do: "#{Float.round(bytes / (1024 * 1024 * 1024), 1)} GB"

  defp format_bytes(bytes), do: "#{Float.round(bytes / (1024 * 1024), 1)} MB"
end
