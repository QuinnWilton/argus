defmodule Argus.Analyses.AtomPrecisionTest do
  use ExUnit.Case, async: true
  @moduletag :flowlog

  alias Argus.Test.Fixtures.AtomPrecision, as: Fixture
  alias Argus.Test.Memo

  setup_all do
    {:ok, result} =
      Memo.analyze([Fixture, Fixture.ConfigPlug, Fixture.RequestPlug], :unsafe_input)

    rows = result["sink_without_request_path"] ++ result["sink_reachable"]
    %{rows: rows}
  end

  defp reported?(rows, name),
    do: Enum.any?(rows, fn [_, func | _] -> String.ends_with?(func, name) end)

  test "fixed table selection remains finite through interpolation", %{rows: rows} do
    for name <- ["ansi/1", "table/1", "table_fetch/1", "table_nth/1", "table_default/1"] do
      refute reported?(rows, ":" <> name), name
    end
  end

  test "an unknown table, fallback, or alternative path remains unbounded", %{rows: rows} do
    assert reported?(rows, ":runtime_table/2")
    assert reported?(rows, ":unknown_default/2")
    assert reported?(rows, ":table_one_branch/3")
  end

  test "request reachability does not make configured atoms request-selected", %{rows: rows} do
    refute reported?(rows, ".ConfigPlug:suffix/1")
    assert reported?(rows, ".RequestPlug:suffix/1")
  end

  test "token guards retain correlations without dropping unknown alternatives", %{rows: rows} do
    refute reported?(rows, ":token/3")
    assert reported?(rows, ":independent_token/3")
    assert reported?(rows, ":partial_token/4")
    assert reported?(rows, ":numeric_equivalence/2")
  end

  test "numeric equivalence counts every value before interpolating independent parameters", %{
    rows: rows
  } do
    assert reported?(rows, ":loose_numeric_product/11")
    refute reported?(rows, ":loose_numeric_small/5")
    refute reported?(rows, ":exact_numeric_product/11")
    assert reported?(rows, ":loose_numeric_list/1")
    refute reported?(rows, ":exact_numeric_list/1")
  end

  test "boolean comparison bounds and joins preserve numeric representations" do
    alias Argus.Extractors.ParamFlow.Bounded

    state = %{
      bounded: %{},
      binaries: MapSet.new(),
      lists: %{},
      groups: [],
      pending: %{},
      ranges: %{},
      returns: %{}
    }

    for {literal, values} <- [
          {{:integer, 1}, [1, 1.0]},
          {{:float, 1.5}, [1.5]},
          {{:integer, 0}, [0, 0.0, -0.0]}
        ] do
      result = Bounded.step({:bif, :==, {:f, 0}, [{:x, 0}, literal], {:x, 1}}, state)
      assert {_, {:values, {:set, actual}}} = result.pending[{:x, 1}]
      assert MapSet.new(actual) == MapSet.new(values)
    end

    composite = {:bif, :==, {:f, 0}, [{:x, 0}, {:literal, [1]}], {:x, 1}}
    assert Bounded.step(composite, state).pending == %{}

    one = %{{:x, 0} => {:values, {:set, [1]}}}
    float = %{{:x, 0} => {:values, {:set, [1.0]}}}
    joined = Bounded.common_entries([one, float])
    assert joined == Bounded.common_entries([float, one])
    assert %{{:x, 0} => {:values, {:set, values}}} = joined
    assert MapSet.new(values) == MapSet.new([1, 1.0])
  end

  test "private helpers inherit finite arguments only from every possible caller", %{rows: rows} do
    refute reported?(rows, ":private_reversed/1")
    refute reported?(rows, ":mapped_delimiter/1")
    assert reported?(rows, ":unknown_delimiter/1")
    assert reported?(rows, ":rescued_result/2")
    assert reported?(rows, ":mixed_token/1")
    assert reported?(rows, ":public_token/1")
  end

  test "Enum.reverse is finite only for proper list alternatives within the total budget", %{
    rows: rows
  } do
    refute reported?(rows, ":enum_token/1")
    refute reported?(rows, ":enum_budget_boundary/2")

    for name <- [
          ":mixed_enum_token/1",
          ":unknown_enum_tail/2",
          ":improper_enum_tail/1",
          ":oversized_enum_product/2",
          ":custom_enumerable/1",
          ":custom_string_chars/1"
        ] do
      assert reported?(rows, name), name
    end
  end

  test "proven binary conversion results retain finite bounds through protocol calls", %{
    rows: rows
  } do
    refute reported?(rows, ":converted_binary/1")
    refute reported?(rows, ":binary_atom_name/1")
    assert reported?(rows, ":binary_or_custom/2")
    assert reported?(rows, ":custom_string_chars/1")
  end

  test "exact list expansion has a deterministic size budget" do
    alias Argus.Extractors.ParamFlow.Bounded

    state = %{
      bounded: %{{:x, 0} => {:values, {:set, [List.duplicate(?x, 4096)]}}},
      binaries: MapSet.new(),
      lists: %{},
      groups: [],
      pending: %{},
      ranges: %{},
      returns: %{}
    }

    # The product is one value, but keeping its exact list would exceed the
    # cell budget. A count-only bound remains valid for other pure operations.
    result = Bounded.step({:put_list, {:integer, ?x}, {:x, 0}, {:x, 0}}, state)
    refute match?({:values, {:set, _}}, result.bounded[{:x, 0}])
  end

  test "escaped helpers and recursive vocabulary growth never gain a finite proof" do
    assert {:ok, facts} =
             Argus.Pipeline.extract([Fixture], extractors: [Argus.Extractors.ParamFlow])

    for name <- [":captured_token/1", ":accumulating_token/2"] do
      refute Enum.any?(facts[:sink_arg_bounded], fn [_, func | _] ->
               String.ends_with?(func, name)
             end)
    end
  end

  test "call-path evidence does not assert that the value is attacker-controlled" do
    finding =
      Argus.Analyses.UnsafeInput.finding(:sink_reachable, [
        "M:convert/1#4",
        "M:convert/1",
        ":erlang.binary_to_atom/1",
        "atom",
        "M:call/2",
        "plug",
        "transitive",
        "",
        "0",
        ""
      ])

    assert finding.detail =~ "If caller-influenced values reach this conversion"
    refute finding.detail =~ "every distinct value an attacker supplies"
  end
end
