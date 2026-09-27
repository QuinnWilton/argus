defmodule Argus.Project.Beams do
  @moduledoc """
  Beams with no build tool argus knows: the program is the directories
  named with `ebins:` (`--ebin DIR`), its dependencies those named with
  `dep_ebins:` (`--dep-ebin DIR`), each named by its `.app` file or else
  by the directory above it; explicit `apps:`/`deps:` pairs name their
  own. The state is `.argus` under the root. argus knows no command that
  builds them, and no sources to compare them with.
  """

  @behaviour Argus.Project

  alias Argus.Project

  @impl true
  def detect?(_root), do: false

  @impl true
  def load(root, opts) do
    apps = named(opts, :ebins, root) ++ (Project.explicit(opts, :apps, root) || [])
    deps = named(opts, :dep_ebins, root) ++ (Project.explicit(opts, :deps, root) || [])

    with :ok <- Project.require_beams(apps, root, nil) do
      {:ok,
       %Project{
         kind: :beams,
         root: root,
         apps: apps,
         deps: deps,
         state_dir: Keyword.get(opts, :state_dir) || Path.join(root, ".argus")
       }}
    end
  end

  defp named(opts, key, root) do
    for dir <- Keyword.get(opts, key, []) do
      ebin = Path.expand(dir, root)
      {app_name(ebin), ebin}
    end
  end

  # The application an ebin's `.app` file names, else the directory
  # above the ebin (`<app>/ebin`), else the ebin's own name.
  defp app_name(ebin) do
    case ebin |> Path.join("*.app") |> Path.wildcard() do
      [app] ->
        app |> Path.basename(".app") |> String.to_atom()

      _ ->
        if Path.basename(ebin) == "ebin",
          do: ebin |> Path.dirname() |> Path.basename() |> String.to_atom(),
          else: ebin |> Path.basename() |> String.to_atom()
    end
  end
end
