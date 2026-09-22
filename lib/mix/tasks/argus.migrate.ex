defmodule Mix.Tasks.Argus.Migrate do
  @shortdoc "Carry pinned finding counts over from retired analysis names"

  @moduledoc """
  Rewrites the `expectations:` block of encore manifests through the
  alias table, so counts pinned under retired analysis names land under
  the concerns their findings live in now.

      mix argus.migrate encore path/to/manifest.exs [more manifests...]

  A count whose retired name maps to one concern moves there and adds to
  that concern's count; one whose name spans several concerns is dropped
  from the map and listed, since only a measurement can say how it
  splits. Run encore's `mix encore diff` afterwards and pin those by
  hand, with the reason.
  """

  use Mix.Task

  @impl Mix.Task
  def run(["encore" | paths]) when paths != [] do
    Mix.Task.run("app.start", ["--no-start"])

    for path <- paths do
      case Argus.Migrate.migrate_manifest(path) do
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

  def run(_args), do: Mix.raise("usage: mix argus.migrate encore MANIFEST [MANIFEST...]")
end
