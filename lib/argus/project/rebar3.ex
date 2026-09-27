defmodule Argus.Project.Rebar3 do
  @moduledoc """
  A rebar3 project, built into `_build/<profile>/lib/<app>/ebin`.

  Its program is every application of its own — the root app and each
  of `apps/*` and `lib/*` (rebar3's `project_app_dirs`, or the list the
  `rebar.config` gives), as one program: an umbrella's apps call one
  another as one system does. Every other application in the profile's
  `lib/` (and `checkouts/`) is a dependency. The state is
  `_build/<profile>/argus`.

  The rebar3 plugin passes the exact ebins rebar3 built (`apps:`,
  `deps:`); without them they are found as above.
  """

  @behaviour Argus.Project

  alias Argus.Project

  @default_app_dirs ["apps/*", "lib/*", "."]

  @impl true
  def detect?(root), do: File.regular?(Path.join(root, "rebar.config"))

  @impl true
  def load(root, opts) do
    profile = Keyword.get(opts, :profile, "default")
    build_dir = Path.join([root, "_build", profile])
    build = if profile == "default", do: "rebar3 compile", else: "rebar3 as #{profile} compile"

    with {:ok, app_dirs} <- app_dirs(root) do
      own = for {name, _dir} <- app_dirs, do: name
      lib = Path.join(build_dir, "lib")

      apps =
        Project.explicit(opts, :apps, root) ||
          for(
            {name, _dir} <- app_dirs,
            do: {name, Path.join([lib, Atom.to_string(name), "ebin"])}
          )

      deps =
        Project.explicit(opts, :deps, root) ||
          Project.lib_ebins(lib, own) ++ Project.lib_ebins(Path.join(build_dir, "checkouts"), own)

      with :ok <- Project.require_beams(apps, root, build) do
        {:ok,
         %Project{
           kind: :rebar3,
           root: root,
           apps: apps,
           deps: deps,
           state_dir: Keyword.get(opts, :state_dir) || Path.join(build_dir, "argus"),
           build: build,
           sources: sources(app_dirs, apps)
         }}
      end
    end
  end

  # Each application of the project's own: the directory holding its
  # src/<name>.app.src, under each of the project's app dirs.
  defp app_dirs(root) do
    with {:ok, patterns} <- project_app_dirs(root) do
      dirs =
        for pattern <- patterns,
            dir <- root |> Path.join(pattern) |> Path.wildcard() |> Enum.sort(),
            app_src <- dir |> Path.join("src/*.app.src") |> Path.wildcard() |> Enum.sort(),
            uniq: true,
            do: {app_src |> Path.basename(".app.src") |> String.to_atom(), Path.expand(dir)}

      {:ok, dirs}
    end
  end

  defp project_app_dirs(root) do
    case :file.consult(String.to_charlist(Path.join(root, "rebar.config"))) do
      {:ok, terms} ->
        case List.keyfind(terms, :project_app_dirs, 0) do
          {:project_app_dirs, dirs} when is_list(dirs) -> {:ok, Enum.map(dirs, &to_string/1)}
          _ -> {:ok, @default_app_dirs}
        end

      {:error, reason} ->
        {:error, "rebar.config cannot be read: #{inspect(reason)}"}
    end
  end

  defp sources(app_dirs, apps) do
    for {name, dir} <- app_dirs,
        {^name, ebin} <- apps,
        do: {Path.join(dir, "src"), ebin, :erlang}
  end
end
