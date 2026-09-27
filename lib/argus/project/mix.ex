defmodule Argus.Project.Mix do
  @moduledoc """
  A Mix project, in the VM Mix runs: the `:argus` compiler and `mix
  argus`. The program is the current project's compile path (an
  umbrella's children each run on their own: the compiler is
  recursive), its dependencies the build's other ebins, and the state
  Mix's manifest path, beside the compilers' own manifests.

  The escript does not analyze a Mix project: `mix argus` runs in the
  project's own VM, with its own Elixir, and compiles it first.
  """

  @behaviour Argus.Project

  @impl true
  def detect?(root), do: File.regular?(Path.join(root, "mix.exs"))

  @doc """
  The current Mix project. `root` must be the project's directory (the
  working directory Mix runs in); explicit `apps:`/`deps:` and
  `state_dir:` are honoured as for every adapter.
  """
  @impl true
  def load(root, opts) do
    if Mix.Project.get() do
      {:ok, current(root, opts)}
    else
      {:error,
       "#{root} is a Mix project: run `mix argus` in it " <>
         "(with {:panoptes, ...} among its dependencies)"}
    end
  end

  @doc "The Mix project the VM is in."
  @spec current(Path.t(), [Argus.Project.option()]) :: Argus.Project.t()
  def current(root \\ File.cwd!(), opts \\ []) do
    compile_path = Mix.Project.compile_path()
    app = Mix.Project.config()[:app]

    %Argus.Project{
      kind: :mix,
      root: root,
      apps: Argus.Project.explicit(opts, :apps, root) || [{app, compile_path}],
      deps:
        Argus.Project.explicit(opts, :deps, root) ||
          Mix.Project.build_path()
          |> Path.join("lib")
          |> Argus.Project.lib_ebins()
          |> Enum.reject(fn {_name, ebin} -> ebin == compile_path end),
      state_dir: Keyword.get(opts, :state_dir) || Mix.Project.manifest_path(),
      build: "mix compile"
    }
  end
end
