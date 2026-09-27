defmodule Argus.Project.Gleam do
  @moduledoc """
  A Gleam project on the Erlang target, built into
  `build/dev/erlang/<package>/ebin`: the program is the package
  `gleam.toml` names, its dependencies every other package there, the
  state `build/argus`.

  The `<package>@@main` module a Gleam build writes to run the package
  (`gleam run`'s entry point) is its own code, not the project's: it is
  watched, never analyzed.

  A documented limit: a Gleam module's beam records the Erlang source
  the compiler generated (`build/dev/erlang/<package>/_gleam_artefacts/
  <module>.erl`, the module named `package@module`), so findings point
  into that file, not the `.gleam` one.
  """

  @behaviour Argus.Project

  alias Argus.Project

  @impl true
  def detect?(root), do: File.regular?(Path.join(root, "gleam.toml"))

  @impl true
  def load(root, opts) do
    erlang = Path.join([root, "build", "dev", "erlang"])

    with {:ok, package} <- package(root) do
      apps =
        Project.explicit(opts, :apps, root) ||
          [{package, Path.join([erlang, Atom.to_string(package), "ebin"])}]

      deps = Project.explicit(opts, :deps, root) || Project.lib_ebins(erlang, [package])

      with :ok <- Project.require_beams(apps, root, "gleam build") do
        {:ok,
         %Project{
           kind: :gleam,
           root: root,
           apps: apps,
           deps: deps,
           state_dir: Keyword.get(opts, :state_dir) || Path.join([root, "build", "argus"]),
           build: "gleam build",
           sources: for({^package, ebin} <- apps, do: {Path.join(root, "src"), ebin, :gleam}),
           generated: [~r/@@main$/]
         }}
      end
    end
  end

  # `name = "package"` at the top of gleam.toml.
  defp package(root) do
    toml = Path.join(root, "gleam.toml")

    with {:ok, content} <- File.read(toml),
         [_, name] <- Regex.run(~r/^\s*name\s*=\s*"([^"]+)"/m, content) do
      {:ok, String.to_atom(name)}
    else
      {:error, reason} -> {:error, "#{toml} cannot be read: #{:file.format_error(reason)}"}
      nil -> {:error, "#{toml} names no package (name = \"...\")"}
    end
  end
end
