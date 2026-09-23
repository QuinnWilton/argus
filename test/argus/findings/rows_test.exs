defmodule Argus.Findings.RowsTest do
  use ExUnit.Case, async: true

  alias Argus.Findings
  alias Argus.Findings.Rows

  doctest Argus.Findings.Rows

  @relation %{
    name: :r,
    doc: "",
    key: {:kind, %{"a" => [:mod]}},
    fields: [{:kind, :symbol, ""}, {:mod, :symbol, ""}, {:site, :symbol, ""}]
  }

  test "a kind the key map does not name, with no default, is one finding per row" do
    rows = [["a", "M", "2"], ["a", "M", "1"], ["b", "M", "2"], ["b", "M", "1"]]
    assert Rows.dedupe(@relation, rows) == [["a", "M", "1"], ["b", "M", "1"], ["b", "M", "2"]]
    assert Findings.dedupe_rows(@relation, rows) == Rows.dedupe(@relation, rows)
  end

  test "position/2 finds a column and raises on one the relation lacks" do
    assert Rows.position(@relation, :site) == 2

    assert_raise ArgumentError, ~r/:nope is not in :r/, fn ->
      Rows.position(@relation, :nope)
    end
  end
end
