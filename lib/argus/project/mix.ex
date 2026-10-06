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

  @doc """
  Compile before a one-shot analysis or debug capture.

  Keep Argus and its dependencies on Mix's code path. An Argus compiler
  diagnostic means findings are available to report; an error from another
  compiler means the BEAMs are stale and must not be analyzed.
  """
  @spec compile!() :: :ok
  def compile! do
    case Mix.Task.run("compile", ["--no-prune-code-paths", "--return-errors"]) do
      {:error, diagnostics} ->
        if Enum.any?(diagnostics, &(&1.severity == :error and &1.compiler_name != "argus")) do
          Mix.raise("argus: the project does not compile; fix the errors above first")
        end

      _ok_or_noop ->
        :ok
    end

    :ok
  end

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
         "(with {:argus_beam, ...} among its dependencies)"}
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
