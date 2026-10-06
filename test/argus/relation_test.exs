defmodule Argus.RelationTest do
  use ExUnit.Case, async: true

  alias Argus.Relation

  test "filters by name, accepts alternatives and drops columns without reordering" do
    rows = [["A", "safe", "1"], ["B", "leak", "2"], ["C", "unknown", "3"]]

    assert Relation.select(rows, [:mod, :kind, :site],
             where: [{"kind", ["leak", "unknown"]}],
             drop: [:kind]
           ) == [["B", "2"], ["C", "3"]]
  end

  test "validates names even for empty relations" do
    assert_raise ArgumentError, ~r/unknown column missing/, fn ->
      Relation.select([], [:site], where: [missing: "x"])
    end

    assert_raise ArgumentError, ~r/unknown column missing/, fn ->
      Relation.select([], [:site], drop: [:missing])
    end
  end

  test "malformed rows are errors, not absent matches" do
    assert_raise ArgumentError, ~r/expected 2 columns/, fn ->
      Relation.select([["a"]], [:func, :site], where: [func: "b"])
    end
  end

  test "bounded consumers do not enumerate the rest of a relation" do
    rows = Stream.concat([["first"]], Stream.map([1], fn _ -> raise "overread" end))
    assert rows |> Relation.stream([:func]) |> Enum.take(1) == [["first"]]
  end
end
