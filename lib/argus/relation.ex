defmodule Argus.Relation do
  @moduledoc """
  Select raw relation rows by column name, without converting values or IDs.

  Both debug inspection and fixture assertions use this contract. Field names
  may be strings or atoms; values remain the strings Soufflé reads and writes.
  Selection preserves row order. Unknown columns and malformed rows raise
  rather than silently selecting the wrong tuple.
  """

  @doc "Select matching rows, optionally dropping named columns."
  @spec select(Enumerable.t(), [atom() | String.t()], keyword()) :: [[String.t()]]
  def select(rows, fields, opts \\ []), do: rows |> stream(fields, opts) |> Enum.to_list()

  @doc "Lazy selection: validates column names once, then checks each row's width."
  @spec stream(Enumerable.t(), [atom() | String.t()], keyword()) :: Enumerable.t()
  def stream(rows, fields, opts \\ []) do
    fields = Enum.map(fields, &to_string/1)
    positions = fields |> Enum.with_index() |> Map.new()
    width = length(fields)

    index = fn column ->
      Map.get(positions, to_string(column)) ||
        raise ArgumentError, "unknown column #{column}; available: #{Enum.join(fields, ", ")}"
    end

    filters = for {column, values} <- Keyword.get(opts, :where, []), do: {index.(column), values}
    dropped = opts |> Keyword.get(:drop, []) |> Enum.map(index) |> MapSet.new()
    kept = for {_name, i} <- Enum.with_index(fields), not MapSet.member?(dropped, i), do: i

    rows
    |> Stream.map(fn row ->
      if length(row) != width do
        raise ArgumentError, "expected #{width} columns, got row #{inspect(row)}"
      end

      row
    end)
    |> Stream.filter(fn row ->
      Enum.all?(filters, fn {i, values} -> Enum.at(row, i) in List.wrap(values) end)
    end)
    |> Stream.map(fn row -> Enum.map(kept, &Enum.at(row, &1)) end)
  end
end
