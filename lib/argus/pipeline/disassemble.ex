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
          required(:line_table) => %{pos_integer() => pos_integer()},
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
  Disassembles a `.beam` file into module data, bundling its imports and
  its Line-chunk table.

  Returns `{:ok, data}` where `data` has the standard BeamSpy disassembly
  shape plus `:imports` and `:line_table` fields, or `{:error, reason}`
  on failure. The line table maps the disassembly's `{:line, ref}`
  references to real source lines (reference 0 — "no location" — has no
  entry); it is empty when the module has no parseable Line chunk, in
  which case no `line_info` facts can be emitted.
  """
  @spec disassemble_path(String.t()) :: {:ok, module_data()} | {:error, term()}
  def disassemble_path(path) do
    with {:ok, data} <- BeamSpy.BeamFile.disassemble(path) do
      {:ok,
       data
       |> Map.put(:imports, fetch_imports(path))
       |> Map.put(:line_table, fetch_line_table(path))}
    end
  end

  defp fetch_imports(path) do
    case BeamSpy.BeamFile.read_imports(path) do
      {:ok, imports} -> imports
      {:error, _} -> []
    end
  end

  defp fetch_line_table(path) do
    case BeamSpy.Source.parse_line_table(path) do
      {:ok, table} -> table
      {:error, _} -> %{}
    end
  end
end
