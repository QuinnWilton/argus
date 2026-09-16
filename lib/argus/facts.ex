defmodule Argus.Facts do
  @moduledoc """
  Schema-driven typed decoding of raw fact rows for in-process consumers.

  `Argus.Pipeline.Emit` produces facts as lists of string fields — the right
  shape for Souffle `.facts` files, but stringly for Elixir consumers. This
  module decodes those rows against `Argus.Schema`: each row becomes a map
  keyed by the schema's field names, with values decoded by field kind
  (numbers and labels to integers, instruction IDs to `Argus.InstrId`
  structs).

  Decoding is *strict*: a row that doesn't match its relation's schema (wrong
  arity, non-numeric number, malformed instruction ID) raises — such a row can
  only come from a bug in an emitter or extractor, and surfacing it loudly at
  the decode boundary beats consumers silently dropping it. Relations not in
  the schema (custom extractor output) pass through undecoded.

  Eventually emission itself may become typed, with stringification pushed to
  the `.facts` writer; this decoder is the compatible first step.
  """

  use Argus.Purity

  alias Argus.{InstrId, Schema, Symbols}

  @typedoc """
  Interned rows: one tuple per row in schema field order, symbol-kinded
  fields as `Argus.Symbols` ids and numeric fields as integers. Relations
  the schema does not know hold their every field as a symbol.
  """
  @type interned :: %{atom() => [tuple()]}

  @type row :: %{atom() => term()}
  @type t :: %{atom() => [row()]}

  @doc """
  Decode a raw facts map (`relation => [[String.t()]]`) into typed rows.
  """
  @spec decode(%{atom() => [[String.t()]]}) :: t()
  @pure true
  def decode(raw) when is_map(raw) do
    Map.new(raw, fn {relation, rows} -> {relation, decode_relation(relation, rows)} end)
  end

  defp decode_relation(relation, rows) do
    case Schema.fetch(relation) do
      {:ok, %{fields: fields}} -> Enum.map(rows, &decode_row(relation, fields, &1))
      :error -> rows
    end
  end

  defp decode_row(relation, fields, row) when length(fields) == length(row) do
    fields
    |> Enum.zip(row)
    |> Map.new(fn {{name, kind, _doc}, value} -> {name, decode_value(relation, kind, value)} end)
  end

  defp decode_row(relation, fields, row) do
    raise ArgumentError,
          "relation #{relation} expects #{length(fields)} fields, got row #{inspect(row)}"
  end

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

  @doc """
  Intern raw rows (`relation => [[String.t()]]`) against `symbols`.
  """
  @spec intern(%{atom() => [[String.t()]]}, Symbols.t()) :: interned()
  def intern(raw, %Symbols{} = symbols) when is_map(raw) do
    # A module's rows repeat the same few thousand strings across every
    # relation (its function IDs; its instruction IDs six relations over),
    # so a pass-local map answers most cells without touching the table.
    {interned, _seen} =
      Enum.map_reduce(raw, %{}, fn {relation, rows}, seen ->
        kinds = field_kinds(relation)

        {rows, seen} =
          Enum.map_reduce(rows, seen, fn row, seen ->
            intern_row(relation, kinds, row, symbols, seen)
          end)

        {{relation, rows}, seen}
      end)

    Map.new(interned)
  end

  @doc """
  The raw rows behind interned ones, field for field.
  """
  @spec materialize(interned(), Symbols.t()) :: %{atom() => [[String.t()]]}
  def materialize(interned, %Symbols{} = symbols) when is_map(interned) do
    Map.new(interned, fn {relation, rows} ->
      kinds = field_kinds(relation)

      {relation,
       Enum.map(rows, fn row ->
         row
         |> Tuple.to_list()
         |> Enum.zip_with(kinds, fn
           value, kind when kind in [:number, :label] -> Integer.to_string(value)
           id, _kind -> Symbols.resolve(symbols, id)
         end)
       end)}
    end)
  end

  @doc """
  Decode interned rows to the same typed rows `decode/1` produces from raw
  ones. Instruction IDs come from the table's parse cache instead of being
  parsed per row.
  """
  @spec decode(interned(), Symbols.t()) :: t()
  def decode(interned, %Symbols{} = symbols) when is_map(interned) do
    # Resolved strings and parsed IDs are held in a pass-local map so an
    # id met in six relations is read from the table once, not six times
    # (every ETS read is a copy).
    {decoded, _seen} =
      Enum.map_reduce(interned, %{}, fn {relation, rows}, seen ->
        case Schema.fetch(relation) do
          {:ok, %{fields: fields}} ->
            {rows, seen} =
              Enum.map_reduce(rows, seen, fn row, seen ->
                decode_interned_row(relation, fields, row, symbols, seen)
              end)

            {{relation, rows}, seen}

          :error ->
            {rows, seen} =
              Enum.map_reduce(rows, seen, fn row, seen ->
                Enum.map_reduce(Tuple.to_list(row), seen, &resolve_cached(symbols, &1, &2))
              end)

            {{relation, rows}, seen}
        end
      end)

    Map.new(decoded)
  end

  # Field kinds in order; an unknown relation is all symbols, as wide as
  # its rows (`:symbol` repeated is what `Stream.cycle` gives the zips).
  defp field_kinds(relation) do
    case Schema.fetch(relation) do
      {:ok, %{fields: fields}} -> Enum.map(fields, fn {_name, kind, _doc} -> kind end)
      :error -> Stream.cycle([:symbol])
    end
  end

  defp intern_row(relation, kinds, row, symbols, seen) do
    {values, seen} = intern_cells(row, kinds, relation, symbols, seen, [])

    if is_list(kinds) and length(values) != length(kinds) do
      raise ArgumentError,
            "relation #{relation} expects #{length(kinds)} fields, got row #{inspect(row)}"
    end

    {List.to_tuple(values), seen}
  end

  # `kinds` is a list for a schema relation and a cycled stream of
  # `:symbol` for an unknown one; walking both by hand keeps the hot loop
  # free of the zip and closure allocations that dominated it.
  defp intern_cells([], _kinds, _relation, _symbols, seen, acc), do: {Enum.reverse(acc), seen}

  defp intern_cells([value | rest], kinds, relation, symbols, seen, acc) do
    {kind, kinds} = next_kind(kinds)

    if kind in [:number, :label] do
      intern_cells(rest, kinds, relation, symbols, seen, [
        decode_value(relation, kind, value) | acc
      ])
    else
      case seen do
        %{^value => id} ->
          intern_cells(rest, kinds, relation, symbols, seen, [id | acc])

        _ ->
          id = Symbols.intern(symbols, value)
          intern_cells(rest, kinds, relation, symbols, Map.put(seen, value, id), [id | acc])
      end
    end
  end

  defp next_kind([kind | rest]), do: {kind, rest}
  defp next_kind([]), do: {:missing, []}
  defp next_kind(stream), do: {:symbol, stream}

  defp decode_interned_row(relation, fields, row, symbols, seen)
       when tuple_size(row) == length(fields) do
    {pairs, seen} =
      fields
      |> Enum.zip(Tuple.to_list(row))
      |> Enum.map_reduce(seen, fn
        {{name, kind, _doc}, value}, seen when kind in [:number, :label] ->
          {{name, value}, seen}

        {{name, :instr_id, _doc}, id}, seen ->
          {instr_id, seen} = instr_id_cached!(relation, symbols, id, seen)
          {{name, instr_id}, seen}

        {{name, _kind, _doc}, id}, seen ->
          {string, seen} = resolve_cached(symbols, id, seen)
          {{name, string}, seen}
      end)

    {Map.new(pairs), seen}
  end

  defp decode_interned_row(relation, fields, row, _symbols, _seen) do
    raise ArgumentError,
          "relation #{relation} expects #{length(fields)} fields, got row #{inspect(row)}"
  end

  defp resolve_cached(symbols, id, seen) do
    case seen do
      %{^id => string} ->
        {string, seen}

      _ ->
        string = Symbols.resolve(symbols, id)
        {string, Map.put(seen, id, string)}
    end
  end

  defp instr_id_cached!(relation, symbols, id, seen) do
    case seen do
      %{{:instr, ^id} => instr_id} ->
        {instr_id, seen}

      _ ->
        case Symbols.instr_id(symbols, id) do
          {:ok, instr_id} ->
            {instr_id, Map.put(seen, {:instr, id}, instr_id)}

          :error ->
            raise ArgumentError,
                  "relation #{relation}: malformed instruction ID " <>
                    inspect(Symbols.resolve(symbols, id))
        end
    end
  end
end
