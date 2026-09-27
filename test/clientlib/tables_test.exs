defmodule Argus.Clientlib.TablesTest do
  @moduledoc """
  clientlib/tables.dl's one table identity (EtsTable): which tables an
  operation may touch, by kind and identity, as every analysis that asks
  "the same table?" reads it.
  """
  use ExUnit.Case, async: true

  alias Argus.{Pipeline, Souffle}
  alias Argus.Test.Fixtures.CheckThenAct
  alias Argus.Test.Fixtures.MissingRow

  @modules [
    CheckThenAct.EnsuredCache,
    CheckThenAct.TwoTablesOneName,
    MissingRow.HandedDebounce,
    MissingRow.OwnPrivateTable
  ]

  defp priv_dl, do: Path.join(:code.priv_dir(:argus_beam), "dl")

  setup_all do
    unless Souffle.available?(), do: flunk("souffle not installed")

    tmp_dir = Path.join(System.tmp_dir!(), "tables_test_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    facts_dir = Path.join(tmp_dir, "facts")
    {:ok, _} = Pipeline.run(@modules, facts_dir, extractors: Argus.Analyses.Races.extractors())
    :ok = Argus.Analysis.derive_stage0(facts_dir)
    :ok = Argus.Analysis.derive_points_to(facts_dir)

    %{exact: solve(tmp_dir, facts_dir, "exact"), coarse: solve_coarse(tmp_dir, facts_dir)}
  end

  # The words over every operation of the fixtures, keyed by the
  # operation's function.
  defp solve(tmp_dir, facts_dir, name) do
    rules_path = Path.join(tmp_dir, "#{name}.dl")

    File.write!(rules_path, """
    .include "#{Path.join(priv_dl(), "clientlib/imports.dl")}"
    .include "#{Path.join(priv_dl(), "clientlib/otp.dl")}"
    .include "#{Path.join(priv_dl(), "clientlib/vocabulary.dl")}"
    .include "#{Path.join(priv_dl(), "clientlib/tables.dl")}"

    .decl op_table(func: symbol, op: symbol, kind: symbol, ident: symbol)
    .output op_table
    op_table(f, o, k, t) :- ets_op(id, f, _, o, _), ets_table(id, k, t).

    .decl op_any(func: symbol, op: symbol)
    .output op_any
    op_any(f, o) :- ets_op(id, f, _, o, _), may_touch_any_table(id).

    .decl site_of(site: symbol, kind: symbol, ident: symbol)
    .output site_of
    site_of(n, k, t) :- site_table(n, k, t).
    """)

    out = Path.join(tmp_dir, "out-#{name}")
    File.mkdir_p!(out)
    {:ok, results} = Souffle.run(facts_dir, rules_path, output_dir: out)
    results
  end

  # The same facts, as a bounded stage that resolved EnsuredCache's table
  # coarsely would leave them: its source_table rows kept, and the table
  # marked coarse.
  defp solve_coarse(tmp_dir, facts_dir) do
    coarse_dir = Path.join(tmp_dir, "coarse-facts")
    File.cp_r!(facts_dir, coarse_dir)

    tables =
      Path.join(facts_dir, "table_alloc.facts")
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&String.split(&1, "\t"))
      |> Enum.filter(fn [_, func, _] -> func =~ "EnsuredCache" end)
      |> Enum.map_join(&(List.last(&1) <> "\n"))

    File.write!(Path.join(coarse_dir, "coarse_table.facts"), tables)
    solve(tmp_dir, coarse_dir, "coarse")
  end

  defp tables(results, func_part, op) do
    for [f, o, k, t] <- results["op_table"], f =~ func_part, o == op, uniq: true, do: {k, t}
  end

  defp any?(results, func_part, op),
    do: Enum.any?(results["op_any"], fn [f, o] -> f =~ func_part and o == op end)

  test "a table a helper returns is its :ets.new/2's named table", %{exact: r} do
    assert tables(r, "EnsuredCache:put_if_absent", "lookup") == [{"named", ":ensured_cache"}]
    assert tables(r, "EnsuredCache:put_if_absent", "insert") == [{"named", ":ensured_cache"}]
  end

  test "two unnamed tables made under one atom are two sites", %{exact: r} do
    [{"new", seen}] = tables(r, "TwoTablesOneName:copy", "lookup")
    [{"new", totals}] = Enum.uniq(tables(r, "TwoTablesOneName:copy", "insert"))
    assert seen != totals
  end

  test "a handed-in table is named by the way in, below it too", %{exact: r} do
    [{"handed_in", ident}] = tables(r, "HandedDebounce:log", "lookup")
    assert ident =~ ~r/^param 0 of .*HandedDebounce:log\/3$/
    assert tables(r, "HandedDebounce:drop", "delete") == [{"handed_in", ident}]
    assert any?(r, "HandedDebounce:drop", "delete")
  end

  test "a parameter the program fills with its own table is that table", %{exact: r} do
    assert [{"new", _site}] = tables(r, "OwnPrivateTable:log", "lookup")
    refute any?(r, "OwnPrivateTable:log", "lookup")
  end

  test "a table a bounded stage resolved coarsely names no table", %{coarse: r} do
    assert tables(r, "EnsuredCache:put_if_absent", "lookup") == []
    assert any?(r, "EnsuredCache:put_if_absent", "lookup")
    # What the other fixtures' operations name is left alone.
    assert [{"new", _}] = tables(r, "OwnPrivateTable:log", "lookup")
  end
end
