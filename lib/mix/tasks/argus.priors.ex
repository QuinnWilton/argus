defmodule Mix.Tasks.Argus.Priors do
  @shortdoc "Inspects, clears, exports or imports the priors cache"

  @moduledoc """
  The cache behind `Argus.Priors`: every classifier answer, under
  `ARGUS_PRIORS_DIR` (default `~/.cache/argus/priors`).

      mix argus.priors status                     # generations and entry counts
      mix argus.priors clear [--generation DIR]   # forget answers (all, or one generation)
      mix argus.priors export PATH [--key K ...]  # write a cassette
      mix argus.priors import PATH                # read one back

  A generation is one model, question and prompt version; changing any
  of them makes new keys, so old entries are never wrong, only unused —
  `clear` is housekeeping, not correctness. A cassette is the answers a
  project needs in one file: commit it, and `priors: :cached_only` runs
  the same everywhere without a key.
  """

  use Mix.Task

  alias Argus.Priors.Cache

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.config")

    case args do
      ["status"] ->
        status()

      ["clear" | rest] ->
        clear(rest)

      ["export", path | rest] ->
        export(path, rest)

      ["import", path] ->
        import_cassette(path)

      _ ->
        Mix.raise(
          "usage: mix argus.priors status | clear [--generation DIR] | export PATH [--key K] | import PATH"
        )
    end
  end

  defp status do
    entries = Cache.entries()
    Mix.shell().info("priors cache: #{Cache.root()}")

    if entries == %{} do
      Mix.shell().info("  (empty)")
    else
      for {generation, list} <- Enum.sort(entries) do
        Mix.shell().info("  #{generation}: #{length(list)} entries")
      end
    end
  end

  defp clear(args) do
    {opts, _, _} = OptionParser.parse(args, strict: [generation: :string])
    {:ok, n} = Cache.clear(Cache.root(), Keyword.take(opts, [:generation]))
    Mix.shell().info("removed #{n} entries")
  end

  defp export(path, args) do
    {opts, _, _} = OptionParser.parse(args, strict: [key: :keep])
    keys = Keyword.get_values(opts, :key)
    {:ok, n} = Cache.export(Cache.root(), path, if(keys == [], do: [], else: [keys: keys]))
    Mix.shell().info("wrote #{n} entries to #{path}")
  end

  defp import_cassette(path) do
    case Cache.import(Cache.root(), path) do
      {:ok, n} -> Mix.shell().info("read #{n} entries from #{path}")
      {:error, reason} -> Mix.raise("could not read #{path}: #{inspect(reason)}")
    end
  end
end
