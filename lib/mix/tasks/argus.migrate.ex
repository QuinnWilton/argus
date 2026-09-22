defmodule Mix.Tasks.Argus.Migrate do
  @shortdoc "Carry pinned finding counts over from retired analysis names"

  @moduledoc """
  Rewrites the `expectations:` block of encore manifests through the
  alias table, so counts pinned under retired analysis names land under
  the concerns their findings live in now.

      mix argus.migrate encore [--analyzer a,b] path/to/manifest.exs [more...]

  Only the pinned-count maps are rewritten (by default those of every
  analyzer whose map names a retired analysis; `--analyzer` narrows it
  to the analyzers that already report the concerns), so the comments
  around them survive. A count whose retired name maps to one concern
  moves there and adds to that concern's count; one whose name spans
  several concerns is dropped from the map and listed, since only a
  measurement can say how it splits (a zero is placed under each). Run
  encore's `mix encore diff` afterwards and pin those by hand, with the
  reason.
  """

  use Mix.Task

  @usage "usage: mix argus.migrate encore [--analyzer a,b] MANIFEST [MANIFEST...]"

  @impl Mix.Task
  def run(["encore" | args]) do
    {opts, paths} = OptionParser.parse!(args, strict: [analyzer: :string])

    if paths == [], do: Mix.raise(@usage)

    Mix.Task.run("app.start", ["--no-start"])

    migrate_opts =
      case opts[:analyzer] do
        nil ->
          []

        names ->
          [analyzers: names |> String.split(",", trim: true) |> Enum.map(&String.to_atom/1)]
      end

    for path <- paths do
      case Argus.Migrate.migrate_manifest(path, migrate_opts) do
        {:ok, []} ->
          Mix.shell().info("#{path}: migrated")

        {:ok, notes} ->
          Mix.shell().info("#{path}: migrated; these need measuring and pinning by hand:")

          for {analyzer, analyzer_notes} <- notes,
              {:ambiguous, name, count, targets} <- analyzer_notes do
            Mix.shell().info(
              "  #{analyzer}: #{name} => #{count} spans #{Enum.map_join(targets, ", ", &Atom.to_string/1)}"
            )
          end

        {:error, reason} ->
          Mix.raise("#{path}: #{inspect(reason)}")
      end
    end
  end

  def run(_args), do: Mix.raise(@usage)
end
