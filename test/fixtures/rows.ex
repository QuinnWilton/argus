defmodule Argus.Test.Rows do
  @moduledoc """
  Rows of a merged relation, selected by column name.

  A concern's relation carries a discriminating column (`reason`, `kind`,
  `context`); tests about one of its rows ask for them by that column
  rather than by position, and may drop the discriminating columns to
  keep asserting the shape the rule has always produced.
  """

  @doc """
  The rows of `relation` in `results` whose columns match `where` (a
  value, or a list of allowed values), with the `:drop` columns removed.

      Rows.where(results, :effects, "effect_in_context", context: "transaction", drop: [:context])
  """
  @spec where(map(), atom(), String.t(), keyword()) :: [[String.t()]]
  def where(results, analysis, relation, opts) do
    {drop, where} = Keyword.pop(opts, :drop, [])
    fields = fields!(analysis, relation)

    index = fn column ->
      Enum.find_index(fields, &(&1 == column)) || raise "no column #{column}"
    end

    keep = for {f, i} <- Enum.with_index(fields), f not in drop, do: i

    results
    |> Map.get(relation, [])
    |> Enum.filter(fn row ->
      Enum.all?(where, fn
        {column, allowed} when is_list(allowed) -> Enum.at(row, index.(column)) in allowed
        {column, value} -> Enum.at(row, index.(column)) == value
      end)
    end)
    |> Enum.map(fn row -> Enum.map(keep, &Enum.at(row, &1)) end)
  end

  defp fields!(analysis, relation) do
    {:ok, relations} = Argus.Analysis.output_relations(analysis)

    case Enum.find(relations, &(Atom.to_string(&1.name) == relation)) do
      nil -> raise ArgumentError, "#{analysis} has no output relation #{relation}"
      %{fields: fields} -> Enum.map(fields, fn {name, _, _} -> name end)
    end
  end
end
