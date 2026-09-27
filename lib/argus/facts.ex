defmodule Argus.Facts do
  @moduledoc """
  Schema-driven typed decoding of raw fact rows for in-process consumers.

  `Argus.Pipeline.Emit` produces facts as lists of string fields — the right
  shape for Souffle `.facts` files, but stringly for Elixir consumers. This
  module decodes those rows against the relations' columns
  (`Argus.Schema.columns/1`, its one read of the schema): each row becomes
  a map keyed by the schema's field names, with values decoded by field
  kind (numbers and labels to integers, instruction IDs to `Argus.InstrId`
  structs).

  Decoding is *strict*: a row that doesn't match its relation's schema (wrong
  arity, non-numeric number, malformed instruction ID) raises — such a row can
  only come from a bug in an emitter or extractor, and surfacing it loudly at
  the decode boundary beats consumers silently dropping it. Relations not in
  the schema (custom extractor output) pass through undecoded.

  Eventually emission itself may become typed, with stringification pushed to
  the `.facts` writer; this decoder is the compatible first step.
  """

  alias Argus.{InstrId, Schema}

  @type row :: %{atom() => term()}
  @type t :: %{atom() => [row()]}

  @doc """
  Decode a raw facts map (`relation => [[String.t()]]`) into typed rows.
  """
  # Not `@pure` (`Argus.Purity`): reading a relation's columns records the
  # read in the process dictionary of a producer that tracks its reads
  # (`Argus.Schema.Reads`), an effect by that analysis's definition.
  @spec decode(%{atom() => [[String.t()]]}) :: t()
  def decode(raw) when is_map(raw) do
    # A module's instruction IDs recur across its relations (an
    # instruction's own row, its defs, its uses, its fall-through), so a
    # pass-local map parses each once and every row naming it shares the
    # struct.
    {decoded, _ids} =
      Enum.map_reduce(raw, %{}, fn {relation, rows}, ids ->
        {rows, ids} = decode_relation(relation, rows, ids)
        {{relation, rows}, ids}
      end)

    Map.new(decoded)
  end

  defp decode_relation(relation, rows, ids) do
    case Schema.columns(relation) do
      {:ok, fields} ->
        width = length(fields)
        Enum.map_reduce(rows, ids, &decode_row(relation, fields, width, &1, &2))

      :error ->
        {rows, ids}
    end
  end

  defp decode_row(relation, fields, width, row, ids) when length(row) == width do
    {pairs, ids} = decode_cells(relation, fields, row, ids, [])
    {:maps.from_list(pairs), ids}
  end

  defp decode_row(relation, _fields, width, row, _ids) do
    raise ArgumentError,
          "relation #{relation} expects #{width} fields, got row #{inspect(row)}"
  end

  defp decode_cells(_relation, [], [], ids, acc), do: {acc, ids}

  defp decode_cells(relation, [{name, kind} | fields], [value | row], ids, acc) do
    {decoded, ids} = decode_value(relation, kind, value, ids)
    decode_cells(relation, fields, row, ids, [{name, decoded} | acc])
  end

  defp decode_value(relation, :instr_id, value, ids) do
    case ids do
      %{^value => id} ->
        {id, ids}

      _ ->
        id = decode_value(relation, :instr_id, value)
        {id, Map.put(ids, value, id)}
    end
  end

  defp decode_value(relation, kind, value, ids), do: {decode_value(relation, kind, value), ids}

  defp decode_value(_relation, :symbol, value), do: value
  defp decode_value(_relation, :func_id, value), do: value

  defp decode_value(relation, kind, value) when kind in [:number, :label] do
    case Integer.parse(value) do
      {int, ""} ->
        int

      _ ->
        raise ArgumentError,
              "relation #{relation}: expected #{kind}, got #{inspect(value)}"
    end
  end

  defp decode_value(relation, :instr_id, value) do
    case InstrId.parse(value) do
      {:ok, id} ->
        id

      :error ->
        raise ArgumentError,
              "relation #{relation}: malformed instruction ID #{inspect(value)}"
    end
  end
end
