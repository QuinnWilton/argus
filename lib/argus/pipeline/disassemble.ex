defmodule Argus.Pipeline.Disassemble do
  @moduledoc """
  Resolves module identifiers to `.beam` paths and disassembles them.

  This is the first stage of `Argus.Pipeline`: a thin wrapper around
  `BeamSpy.BeamFile` that handles module-atom, string-path, and raw
  beam-data inputs and bundles imports into the disassembled data so the
  emitter has everything it needs in one place.
  """

  @type module_input :: atom() | String.t() | binary()
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
  Resolves a list of module atoms, `.beam` file paths, or raw beam data
  binaries to a list of disassembly inputs.

  Raw beam data (recognized by `BeamSpy.BeamFile.beam_data?/1` — the
  `"FOR1"` IFF header or gzip magic) passes through untouched; every
  downstream `BeamSpy` reader accepts data and paths interchangeably.
  This lets callers holding in-memory bytecode (e.g. straight from
  `Code.compile_string/2`) analyze it without a temp-file round trip.

  Returns `{:ok, inputs}` or `{:error, {:not_found, ref}}` on the first
  unresolved entry.
  """
  @spec resolve_paths([module_input()]) :: {:ok, [String.t() | binary()]} | {:error, term()}
  def resolve_paths(modules) do
    results =
      Enum.map(modules, fn
        data_or_path when is_binary(data_or_path) ->
          cond do
            BeamSpy.BeamFile.beam_data?(data_or_path) -> {:ok, data_or_path}
            File.exists?(data_or_path) -> {:ok, data_or_path}
            true -> {:error, {:not_found, data_or_path}}
          end

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
  Disassembles a `.beam` file (by path or raw beam data) into module data,
  bundling its imports, its Line-chunk table and the input itself
  (`:beam`, for readers of chunks the disassembly does not carry: the
  specs in its debug info).

  Returns `{:ok, data}` where `data` has the standard BeamSpy disassembly
  shape plus `:imports` and `:line_table` fields, or `{:error, reason}`
  on failure. The line table maps the Line-chunk references a
  disassembly's markers carry to real source lines (reference 0 — "no
  location" — has no entry): every `debug_line`'s, and each `{:line,
  ref}` OTP 28 leaves as it is (OTP 29's disassembler resolves a `line`
  marker to its location itself; `marker_line/2` reads either). It is empty when the module has no parseable Line
  chunk, in which case no `line_info` facts can be emitted.
  """
  @spec disassemble_path(String.t() | binary()) :: {:ok, module_data()} | {:error, term()}
  def disassemble_path(path) do
    # Read once, past the file server, for all three readers: each reads
    # a path again, through it.
    with {:ok, bytes} <- beam_bytes(path),
         {:ok, data} <- BeamSpy.BeamFile.disassemble(bytes) do
      {:ok,
       data
       |> Map.put(:beam, path)
       |> Map.put(:imports, fetch_imports(bytes))
       |> Map.put(:line_table, fetch_line_table(bytes))}
    end
  end

  defp beam_bytes(path) do
    if BeamSpy.BeamFile.beam_data?(path) do
      {:ok, path}
    else
      case Argus.RawFile.read(path) do
        {:ok, bytes} -> {:ok, bytes}
        {:error, reason} -> {:error, {:file_error, reason}}
      end
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

  @doc """
  The source line a line marker names: a reference into the Line chunk,
  looked up in `line_table` (OTP 28's `beam_disasm` leaves a `line`
  marker's reference as it is, and every release a `debug_line`'s), or
  the location OTP 29's resolves a `line` marker to
  (`[{:location, file, line}]`). Nil for no location (reference 0, or
  `[]`) and for a reference the table does not hold.
  """
  @spec marker_line(non_neg_integer() | list(), %{optional(pos_integer()) => non_neg_integer()}) ::
          non_neg_integer() | nil
  def marker_line(ref, line_table) when is_integer(ref), do: Map.get(line_table, ref)
  def marker_line([{:location, _file, line} | _], _line_table) when is_integer(line), do: line
  def marker_line(_no_location, _line_table), do: nil
end
