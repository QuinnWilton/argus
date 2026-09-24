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
  depend on Souffle's row order or on how many sites witness the same
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
  def dedupe(%{key: key_fields, fields: fields} = relation, rows) when is_list(key_fields) do
    positions = key_positions(key_fields, fields)

    rows
    |> Enum.group_by(fn row -> Enum.map(positions, &Enum.at(row, &1)) end)
    |> Enum.map(fn {_key, group} -> representative(relation, group) end)
    |> Enum.sort()
  end

  def dedupe(%{key: {column, keys}, fields: fields} = relation, rows) when is_map(keys) do
    [discriminator] = key_positions([column], fields)

    default =
      case Map.fetch(keys, :default) do
        {:ok, key_fields} -> key_positions(key_fields, fields)
        :error -> Enum.to_list(0..(length(fields) - 1)//1)
      end

    by_value =
      for {value, key_fields} <- keys, value != :default, into: %{} do
        {value, key_positions(key_fields, fields)}
      end

    rows
    |> Enum.group_by(fn row ->
      value = Enum.at(row, discriminator)
      positions = Map.get(by_value, value, default)
      {value, Enum.map(positions, &Enum.at(row, &1))}
    end)
    |> Enum.map(fn {_key, group} -> representative(relation, group) end)
    |> Enum.sort()
  end

  def dedupe(_relation, rows), do: rows

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

  defp key_positions(key_fields, fields) do
    for key_field <- key_fields do
      case Enum.find_index(fields, fn {name, _kind, _doc} -> name == key_field end) do
        nil -> raise ArgumentError, "key field #{inspect(key_field)} not in #{inspect(fields)}"
        position -> position
      end
    end
  end
end
