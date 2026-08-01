defmodule Argus.Lines do
  @moduledoc """
  Resolves anchor IDs to source lines using `line_info` facts.

  Layer 1 stamps every instruction with the source line in effect
  (schema version 3), so an instruction ID resolves to its exact line
  and a function ID to its first stamped line. Build a table once per
  extraction with `from_facts/1` or `from_facts_dir/1`, then `resolve/2`
  the ID forms findings carry: witness-column strings, `Argus.InstrId`
  structs, or MFA tuples.

  Resolution is best-effort by design: IDs from modules without a
  parseable Line chunk, compiler-generated code under a no-location
  marker, and strings that are not IDs at all resolve to `nil`, never a
  guess.
  """

  alias Argus.InstrId

  @typedoc "Line tables: exact per-instruction plus first-line per function."
  @type t :: %{
          by_instr: %{String.t() => pos_integer()},
          by_func: %{String.t() => pos_integer()}
        }

  @doc """
  Builds line tables from an extracted facts map (raw string rows, as
  returned by `Argus.Pipeline.extract/2` with the default format).
  """
  @spec from_facts(%{atom() => [[String.t()]]}) :: t()
  def from_facts(facts) when is_map(facts) do
    facts |> Map.get(:line_info, []) |> build()
  end

  @doc """
  Builds line tables from a `.facts` directory (the `line_info.facts`
  file written by `Argus.Pipeline.run/3`). A missing or unreadable file
  yields empty tables — every lookup resolves to `nil`.
  """
  @spec from_facts_dir(Path.t()) :: t()
  def from_facts_dir(dir) do
    case File.read(Path.join(dir, "line_info.facts")) do
      {:ok, contents} ->
        contents
        |> String.split("\n", trim: true)
        |> Enum.map(&String.split(&1, "\t"))
        |> build()

      {:error, _} ->
        build([])
    end
  end

  defp build(rows) do
    by_instr = Map.new(rows, fn [id, line] -> {id, String.to_integer(line)} end)

    by_func =
      rows
      |> Enum.group_by(
        fn [id, _line] -> id |> String.split("#", parts: 2) |> hd() end,
        fn [_id, line] -> String.to_integer(line) end
      )
      |> Map.new(fn {func, lines} -> {func, Enum.min(lines)} end)

    %{by_instr: by_instr, by_func: by_func}
  end

  @doc """
  Resolves an anchor to its source line, or `nil`.

  Accepts an instruction ID string (`"Mod:func/arity#idx"` — exact
  line), a function ID string (`"Mod:func/arity"` — the function's
  first line), an `Argus.InstrId`, or an MFA tuple. Any other string
  (module names, extractor placeholders like `"dynamic"`) misses both
  tables and resolves to `nil`.
  """
  @spec resolve(t(), String.t() | InstrId.t() | mfa()) :: pos_integer() | nil
  def resolve(lines, %InstrId{} = instr_id) do
    resolve(lines, InstrId.format(instr_id))
  end

  def resolve(lines, {m, f, a}) when is_atom(m) and is_atom(f) and is_integer(a) do
    resolve(lines, InstrId.func_id(m, f, a))
  end

  def resolve(lines, id) when is_binary(id) do
    Map.get(lines.by_instr, id) ||
      Map.get(lines.by_func, id) ||
      instr_func_fallback(lines, id)
  end

  # An instruction ID whose exact line is unknown (no line in effect at
  # that instruction) still names its function — fall back to its first
  # line rather than nothing.
  defp instr_func_fallback(lines, id) do
    case String.split(id, "#", parts: 2) do
      [func, _idx] -> Map.get(lines.by_func, func)
      _ -> nil
    end
  end
end
