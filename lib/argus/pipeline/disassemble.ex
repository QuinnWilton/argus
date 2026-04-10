defmodule Argus.Pipeline.Disassemble do
  @moduledoc """
  Resolves module identifiers to `.beam` paths and disassembles them.

  This is the first stage of `Argus.Pipeline`: a thin wrapper around
  `BeamSpy.BeamFile` that handles both module-atom and string-path inputs
  and bundles imports into the disassembled data so the emitter has
  everything it needs in one place.
  """

  @type module_input :: atom() | String.t()
  @type module_data :: %{
          required(:module) => atom(),
          required(:exports) => list(),
          required(:attributes) => keyword(),
          required(:functions) => list(),
          required(:imports) => list(),
          optional(any()) => any()
        }

  @doc """
  Resolves a list of module atoms or `.beam` file paths to a list of paths.

  Returns `{:ok, paths}` or `{:error, {:not_found, ref}}` on the first
  unresolved entry.
  """
  @spec resolve_paths([module_input()]) :: {:ok, [String.t()]} | {:error, term()}
  def resolve_paths(modules) do
    results =
      Enum.map(modules, fn
        path when is_binary(path) ->
          if File.exists?(path), do: {:ok, path}, else: {:error, {:not_found, path}}

        module when is_atom(module) ->
          case :code.which(module) do
            :non_existing -> {:error, {:not_found, module}}
            :cover_compiled -> {:error, {:cover_compiled, module}}
            path when is_list(path) -> {:ok, List.to_string(path)}
          end
      end)

    case Enum.find(results, &match?({:error, _}, &1)) do
      nil -> {:ok, Enum.map(results, fn {:ok, path} -> path end)}
      error -> error
    end
  end

  @doc """
  Disassembles a `.beam` file into module data, bundling its imports.

  Returns `{:ok, data}` where `data` has the standard BeamSpy disassembly
  shape plus an `:imports` field, or `{:error, reason}` on failure.
  """
  @spec disassemble_path(String.t()) :: {:ok, module_data()} | {:error, term()}
  def disassemble_path(path) do
    with {:ok, data} <- BeamSpy.BeamFile.disassemble(path) do
      {:ok, Map.put(data, :imports, fetch_imports(path))}
    end
  end

  defp fetch_imports(path) do
    case BeamSpy.BeamFile.read_imports(path) do
      {:ok, imports} -> imports
      {:error, _} -> []
    end
  end
end
