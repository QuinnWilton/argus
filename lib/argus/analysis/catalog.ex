defmodule Argus.Analysis.Catalog do
  @moduledoc """
  The built-in analyses: which modules implement `Argus.Analysis`, how
  to find one by name, what it declares, and where its rules live.

  Discovery reads the `:argus_beam` application's module list, keeping the
  modules that export the behaviour's required callbacks, sorted by
  name. Discovery is cached once per VM; the application's module list is
  fixed when it loads. Relation definitions are read through their accessors.

  `Argus.Analysis` delegates its lookup functions here
  (`builtin_analyses/0`, `fetch_module/1`, `output_relations/1`, ...);
  callers use those.
  """

  alias Argus.Analysis

  @doc "The names of the built-in analyses, sorted."
  @spec names() :: [atom()]
  def names, do: Enum.map(modules(), & &1.name())

  @doc """
  The built-in analysis modules, sorted by name. Found once per VM among
  the application's modules (thousands in the test build, whose
  fixtures are compiled into it), and kept: the application's module
  list is fixed when it loads.
  """
  @spec modules() :: [module()]
  def modules do
    case :persistent_term.get({__MODULE__, :modules}, nil) do
      nil ->
        modules =
          argus_modules()
          |> Enum.filter(fn mod ->
            Code.ensure_loaded?(mod) and
              function_exported?(mod, :name, 0) and
              function_exported?(mod, :rules_file, 0) and
              function_exported?(mod, :output_relations, 0)
          end)
          |> Enum.sort_by(& &1.name())

        :persistent_term.put({__MODULE__, :modules}, modules)
        modules

      modules ->
        modules
    end
  end

  @doc "The built-in analysis module named `name`: `{:ok, module}` or `:error`."
  @spec fetch(atom()) :: {:ok, module()} | :error
  def fetch(name) when is_atom(name) do
    case Enum.find(modules(), &(&1.name() == name)) do
      nil -> :error
      mod -> {:ok, mod}
    end
  end

  @doc "The output relations a built-in analysis declares: `{:ok, relations}` or `:error`."
  @spec output_relations(atom()) :: {:ok, [Analysis.output_relation()]} | :error
  def output_relations(name) when is_atom(name) do
    case fetch(name) do
      {:ok, mod} -> {:ok, mod.output_relations()}
      :error -> :error
    end
  end

  @doc """
  The output relations of an analysis whose rows are findings: every
  output relation but the evidence ones and the one that re-tiers them
  (`retier: :tooling`).
  """
  @spec finding_relations(atom()) :: {:ok, [Analysis.output_relation()]} | :error
  def finding_relations(name) do
    with {:ok, relations} <- output_relations(name) do
      {:ok, Enum.reject(relations, &(Map.has_key?(&1, :evidence) or Map.has_key?(&1, :retier)))}
    end
  end

  @doc """
  The FlowLog program an analysis runs: a built-in's `rules_file/0`
  under `priv/dl/`, or a custom program's own path. Either must exist.
  """
  @spec rules_path(Analysis.analysis()) :: {:ok, Path.t()} | {:error, term()}
  def rules_path({:custom, path}) do
    if File.exists?(path) do
      {:ok, path}
    else
      {:error, {:rules_not_found, path}}
    end
  end

  def rules_path(name) when is_atom(name) do
    case fetch(name) do
      {:ok, mod} ->
        path = priv_dl(mod.rules_file())

        if File.exists?(path, [:raw]) do
          {:ok, path}
        else
          {:error, {:rules_not_found, path}}
        end

      :error ->
        {:error, {:unknown_analysis, name}}
    end
  end

  @doc """
  A file under the Datalog tree (`Argus.Dl.root/0`): the shipped rules,
  or the directory the `:dl_root` application variable names (a copy a
  test edits a rule in, in a VM of its own).
  """
  @spec priv_dl(String.t()) :: Path.t()
  def priv_dl(filename), do: Argus.Dl.path(filename)

  # The :modules key only exists once the application is *loaded* — which
  # plain code-path embedding (escripts, sandbox VMs that only call
  # :code.add_paths/1) never does. Loading is cheap, idempotent, and does
  # not start anything, so do it on demand rather than crash.
  defp argus_modules do
    case :application.get_key(:argus_beam, :modules) do
      {:ok, modules} ->
        modules

      :undefined ->
        case :application.load(:argus_beam) do
          ok when ok in [:ok, {:error, {:already_loaded, :argus_beam}}] ->
            :ok

          {:error, reason} ->
            raise "could not load the :argus_beam application: #{inspect(reason)}"
        end

        {:ok, modules} = :application.get_key(:argus_beam, :modules)
        modules
    end
  end
end
