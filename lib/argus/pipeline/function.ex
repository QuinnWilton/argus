defmodule Argus.Pipeline.Function do
  @moduledoc """
  A function's analysis input, independent of module-wide compiler numbering.

  Branch labels are local to the function. Closure targets keep their resolved
  MFA and captures; the loader's lambda index and module checksum are discarded.
  Source markers keep their positions, equality and ordering. Absolute source
  locations must be read from the original disassembly when locating findings.

  This is an analysis representation, not bytecode that can be executed.
  Literal payloads are never rewritten.
  """

  alias Argus.Pipeline.Disassemble

  @type t :: {:function, atom(), non_neg_integer(), non_neg_integer(), list()}

  @doc "Indexes entry labels by their resolved function target."
  @spec entries(Disassemble.module_data()) :: map()
  def entries(%{module: module, functions: functions}) do
    Map.new(functions, fn {:function, name, arity, entry, _} ->
      {entry, {module, name, arity}}
    end)
  end

  @doc "Returns a canonical function and its relative source-line table."
  @spec canonical(t(), map(), map()) :: {t(), map()}
  def canonical({:function, _, _, _, _} = original, line_table, entries) do
    {{:function, name, arity, entry, instructions}, table} = relative_lines(original, line_table)

    labels =
      instructions
      |> Enum.flat_map(fn
        {:label, label} -> [label]
        _ -> []
      end)
      |> Enum.with_index(1)
      |> Map.new()
      |> Map.put(0, 0)

    instructions = Enum.map(instructions, &(&1 |> closure(entries) |> remap(labels)))
    {{:function, name, arity, Map.fetch!(labels, entry), instructions}, table}
  rescue
    # Unknown label-bearing operands retain their original numbering. A new
    # compiler shape can cost reuse without making the function unanalyzable.
    KeyError -> relative_lines(original, line_table)
  end

  defp relative_lines({:function, name, arity, entry, instructions}, line_table) do
    lines =
      instructions
      |> Enum.map(&source_line(&1, line_table))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.with_index(1)
      |> Map.new()

    instructions = Enum.map(instructions, &location(&1, line_table, lines))
    function = {:function, name, arity, entry, instructions}
    {function, Map.new(Map.values(lines), &{&1, &1})}
  end

  defp source_line({:line, marker}, table), do: Disassemble.marker_line(marker, table)

  defp source_line({:debug_line, _, marker, _, _}, table),
    do: Disassemble.marker_line(marker, table)

  defp source_line(_, _), do: nil

  defp location({:line, _} = instruction, table, lines),
    do: {:line, Map.get(lines, source_line(instruction, table), 0)}

  defp location({:debug_line, kind, _, _index, live} = instruction, table, lines),
    do: {:debug_line, kind, Map.get(lines, source_line(instruction, table), 0), 0, live}

  defp location(instruction, _, _), do: instruction

  defp closure({:make_fun3, target, _index, _uniq, dst, env}, entries),
    do: {:make_fun3, target(target, entries), 0, 0, dst, env}

  defp closure({:make_fun2, target, _index, _uniq, free}, entries),
    do: {:make_fun2, target(target, entries), 0, 0, free}

  # OTP resolves this type hint to the target's entry label, which can belong
  # to another function. It is not a control-flow branch in this function.
  defp closure({:call_fun2, {:f, label}, arity, fun}, entries),
    do: {:call_fun2, {:function, Map.fetch!(entries, label)}, arity, fun}

  defp closure(instruction, _), do: instruction

  defp target({:f, label}, entries), do: Map.fetch!(entries, label)
  defp target(mfa, _), do: mfa

  defp remap({:literal, _} = literal, _), do: literal

  defp remap({kind, label}, labels) when kind in [:label, :f],
    do: {kind, Map.fetch!(labels, label)}

  defp remap(tuple, labels) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> Enum.map(&remap(&1, labels)) |> List.to_tuple()

  defp remap([head | tail], labels), do: [remap(head, labels) | remap(tail, labels)]
  defp remap(value, _), do: value
end
