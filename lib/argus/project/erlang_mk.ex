defmodule Argus.Project.ErlangMk do
  @moduledoc """
  An erlang.mk project: the program is `ebin/`, named by the Makefile's
  `PROJECT`, its dependencies `deps/*/ebin`, the state
  `.erlang.mk/argus`.
  """

  @behaviour Argus.Project

  alias Argus.Project

  @impl true
  def detect?(root) do
    File.regular?(Path.join(root, "erlang.mk")) or
      match?({:ok, _}, makefile_including_erlang_mk(root))
  end

  @impl true
  def load(root, opts) do
    name = project_name(root)
    apps = Project.explicit(opts, :apps, root) || [{name, Path.join(root, "ebin")}]
    deps = Project.explicit(opts, :deps, root) || Project.lib_ebins(Path.join(root, "deps"))

    with :ok <- Project.require_beams(apps, root, "make") do
      {:ok,
       %Project{
         kind: :erlang_mk,
         root: root,
         apps: apps,
         deps: deps,
         state_dir: Keyword.get(opts, :state_dir) || Path.join([root, ".erlang.mk", "argus"]),
         build: "make",
         sources: for({^name, ebin} <- apps, do: {Path.join(root, "src"), ebin, :erlang})
       }}
    end
  end

  defp makefile_including_erlang_mk(root) do
    with {:ok, content} <- File.read(Path.join(root, "Makefile")),
         true <- content =~ ~r/^\s*-?include\s+\S*erlang\.mk/m do
      {:ok, content}
    else
      _ -> :error
    end
  end

  # `PROJECT = name` in the Makefile, else the directory's name.
  defp project_name(root) do
    with {:ok, content} <- File.read(Path.join(root, "Makefile")),
         [_, name] <- Regex.run(~r/^\s*PROJECT\s*[:?]?=\s*(\S+)/m, content) do
      String.to_atom(name)
    else
      _ -> root |> Path.basename() |> String.to_atom()
    end
  end
end
