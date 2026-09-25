defmodule Argus.Extractors.ParamFlow.PropagatorsTest do
  @moduledoc """
  Every propagator position is checked against the callee's documented
  signature: a position that names a key, an index, a count or a
  function is not where the data comes from. `:maps.get(Key, Map)` was
  recorded at position 0, so taint through a direct `:maps.get` was lost.
  """
  use ExUnit.Case, async: true

  alias Argus.Extractors.ParamFlow.Propagators

  # Argument names that are never the data a result is made of.
  @not_data ~w(key keys n index pos position fun pred predicate mapper sorter count len length
    start stop timeout opts options)

  test "no listed position is a key, an index, a count or a function" do
    wrong =
      for {mod, funs, arities, positions} <- Propagators.entries(),
          {fun, arity, names} <- documented(mod, funs, arities),
          pos <- positions,
          pos < arity,
          name = Enum.at(names, pos),
          normalize(name) in @not_data,
          do: {mod, fun, arity, pos, name}

    assert wrong == []
  end

  test "the audited positions" do
    assert Propagators.positions(":maps", "get", 2) == [1]
    assert Propagators.positions(":maps", "get", 3) == [1, 2]
    assert Propagators.positions(":lists", "nthtail", 2) == [1]
    assert Propagators.positions(":lists", "sort", 2) == [1]
    assert Propagators.positions(":lists", "reverse", 2) == [0, 1]
    assert Propagators.positions("Tuple", "insert_at", 3) == [0, 2]
    assert Propagators.positions("Map", "get", 3) == [0, 2]
    assert Propagators.positions("Regex", "named_captures", 2) == [1]
    assert Propagators.positions("Regex", "replace", 4) == [1, 2]
    assert Propagators.positions(":re", "run", 3) == [0]
  end

  # {fun, arity, argument names} for every documented function of `mod`
  # the entry covers.
  defp documented(mod, funs, arities) do
    case Code.fetch_docs(mod) do
      {:docs_v1, _, _, _, _, _, docs} ->
        for {{kind, fun, arity}, _, [signature | _], _, _} <- docs,
            kind in [:function, :macro],
            funs == :any or fun in funs,
            covers?(arities, arity),
            names = arg_names(signature),
            length(names) == arity,
            do: {fun, arity, names}

      _ ->
        []
    end
  end

  defp covers?(:any, _arity), do: true
  defp covers?(arities, arity) when is_list(arities), do: arity in arities
  defp covers?(arities, arity), do: arities == arity

  # "get(Key, Map)" -> ["Key", "Map"]; "get(map, key, default \\ nil)" ->
  # ["map", "key", "default"].
  defp arg_names(signature) do
    case Regex.run(~r/^[^(]*\((.*)\)[^)]*$/s, signature) do
      [_, ""] ->
        []

      [_, args] ->
        args
        |> split_top_level()
        |> Enum.map(fn arg -> arg |> String.split("\\\\") |> hd() |> String.trim() end)

      nil ->
        []
    end
  end

  defp split_top_level(args) do
    {parts, current, _depth} =
      args
      |> String.graphemes()
      |> Enum.reduce({[], "", 0}, fn
        ",", {parts, current, 0} -> {[current | parts], "", 0}
        c, {parts, current, depth} when c in ["(", "[", "{"] -> {parts, current <> c, depth + 1}
        c, {parts, current, depth} when c in [")", "]", "}"] -> {parts, current <> c, depth - 1}
        c, {parts, current, depth} -> {parts, current <> c, depth}
      end)

    Enum.reverse([current | parts])
  end

  defp normalize(name),
    do: name |> String.downcase() |> String.replace(~r/[0-9_]/, "")
end
