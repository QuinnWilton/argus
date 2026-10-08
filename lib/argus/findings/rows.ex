defmodule Argus.Findings.Rows do
  @moduledoc """
  An output relation's rows as findings see them: which rows are one
  finding, and where a column sits.

  A relation with witness columns yields one row per witnessing site;
  its `:key` (`t:Argus.Analysis.row_key/0`) names the columns that make
  a row one finding, and `dedupe/2` keeps one row per key. Every
  consumer that turns rows into findings goes through it — `run/2`,
  `Argus.Findings.build/2`, and embedders that count rows themselves —
  so a finding count is the same whoever counts.

  `Argus.Findings.dedupe_rows/2` delegates to `dedupe/2`.
  """

  alias Argus.Analysis
  alias Argus.InstrId

  @doc """
  Deduplicates a relation's rows down to one per logical finding.

  Relations with witness columns yield one row per witnessing site; rows
  that agree on the relation's declared `:key` fields describe the same
  finding. Keeps the lexicographically least row of each group — a
  deterministic representative, so finding counts and anchors never
  depend on an engine's row order or on how many sites witness the same
  defect. Relations without a `:key` pass through unchanged.

  A key chosen by the value of a discriminating column
  (`{column, %{value => key, default: key}}`) lets each kind of row in a
  merged relation say what identifies it. A kind the map does not name,
  with no `:default`, keeps every column: one finding per row, never two
  rows folded into one on a guess.

  A relation that declares `earliest: column` keeps, of each group, the
  row whose `column` is the earliest instruction in its function instead
  (a row whose column is empty or not an instruction ID comes last, the
  least row breaking ties). "The call that starts the path" is the first
  such call, and instruction IDs do not sort by position as strings —
  `"M:f/1#12"` is less than `"M:f/1#6"`.

      iex> relation = %{
      ...>   name: :r,
      ...>   doc: "",
      ...>   key: [:mod],
      ...>   fields: [{:mod, :symbol, ""}, {:site, :symbol, ""}]
      ...> }
      iex> Argus.Findings.Rows.dedupe(relation, [["B", "2"], ["A", "9"], ["A", "1"]])
      [["A", "1"], ["B", "2"]]
  """
  @spec dedupe(Analysis.output_relation(), [[String.t()]]) :: [[String.t()]]
  def dedupe(%{key: key} = relation, rows) when is_list(key) or is_tuple(key) do
    rows
    |> Enum.group_by(row_key(relation))
    |> Enum.map(fn {_key, group} -> representative(relation, group) end)
    |> Enum.sort()
  end

  def dedupe(_relation, rows), do: rows

  # What makes two rows one finding: the values of the key columns, or,
  # for a key chosen by a column's value, that value and the columns it
  # chooses (every column for a value the key does not name).
  defp row_key(%{key: key_fields} = relation) when is_list(key_fields) do
    positions = positions(relation, key_fields)
    &values_at(&1, positions)
  end

  defp row_key(%{key: {column, keys}, fields: fields} = relation) when is_map(keys) do
    discriminator = position(relation, column)

    default =
      case Map.fetch(keys, :default) do
        {:ok, key_fields} -> positions(relation, key_fields)
        :error -> Enum.to_list(0..(length(fields) - 1)//1)
      end

    by_value =
      for {value, key_fields} <- keys,
          value != :default,
          into: %{},
          do: {value, positions(relation, key_fields)}

    fn row ->
      value = Enum.at(row, discriminator)
      {value, values_at(row, Map.get(by_value, value, default))}
    end
  end

  defp positions(relation, columns), do: Enum.map(columns, &position(relation, &1))
  defp values_at(row, positions), do: Enum.map(positions, &Enum.at(row, &1))

  defp representative(%{earliest: column} = relation, group) do
    at = position(relation, column)
    Enum.min_by(group, fn row -> {instr_rank(Enum.at(row, at)), row} end)
  end

  defp representative(_relation, group), do: Enum.min(group)

  defp instr_rank(id) do
    case InstrId.parse(id) do
      {:ok, %InstrId{idx: idx}} -> {0, idx}
      :error -> {1, 0}
    end
  end

  @doc """
  The position of `column` among a relation's fields. A column the
  relation does not have is a bug in the analysis module declaring it,
  and raises.
  """
  @spec position(Analysis.output_relation(), atom()) :: non_neg_integer()
  def position(relation, column) do
    Enum.find_index(relation.fields, fn {name, _kind, _doc} -> name == column end) ||
      raise ArgumentError, "column #{inspect(column)} is not in #{inspect(relation.name)}"
  end

  @doc """
  A row as `name=value` pairs, for the generic rendering of a row no
  builder rendered.

      iex> relation = %{name: :r, doc: "", fields: [{:mod, :symbol, ""}, {:n, :number, ""}]}
      iex> Argus.Findings.Rows.raw_columns(relation, ["M", "3"])
      "mod=M, n=3"
  """
  @spec raw_columns(Analysis.output_relation(), [String.t()]) :: String.t()
  def raw_columns(relation, row) do
    relation.fields
    |> Enum.zip(row)
    |> Enum.map_join(", ", fn {{name, _kind, _doc}, value} -> "#{name}=#{value}" end)
  end
end
