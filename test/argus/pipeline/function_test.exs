defmodule Argus.Pipeline.FunctionTest do
  use ExUnit.Case, async: true

  alias Argus.Pipeline.Function

  test "partition failures retain the pipeline's extraction error result" do
    data = %{
      module: BrokenPartition,
      functions: [:malformed_function],
      exports: [],
      imports: [],
      attributes: [],
      line_table: %{}
    }

    assert {:ok, %{base: nil, facts: %{base: %{extraction_error: bytes}}}} =
             Argus.Pipeline.extract_data(data, producers: [:base], keep_base: true)

    assert [["BrokenPartition", "pipeline", reason]] = Argus.Tsv.decode(bytes)
    assert reason =~ "FunctionClauseError"
  end

  test "compiler numbering is independent of targets, captures, and literal data" do
    make = fn label, index, uniq, target ->
      {:function, :outer, 1, label,
       [
         {:label, label},
         {:make_fun3, {:f, target}, index, uniq, {:x, 0}, {:list, [{:x, 1}]}},
         {:call_fun2, {:f, target}, 0, {:x, 0}},
         {:move, {:literal, [{:f, 900} | 4]}, {:x, 1}},
         {:jump, {:f, label}}
       ]}
    end

    {a, _} = Function.canonical(make.(12, 0, 44, 20), %{}, %{20 => {Example, :inner, 1}})
    {b, _} = Function.canonical(make.(80, 9, 55, 88), %{}, %{88 => {Example, :inner, 1}})
    {c, _} = Function.canonical(make.(80, 9, 55, 88), %{}, %{88 => {Example, :other, 1}})
    assert a == b
    refute a == c
    assert {:move, {:literal, [{:f, 900} | 4]}, {:x, 1}} in elem(a, 4)
  end

  test "relative locations preserve order, equal lines, and missing locations" do
    function =
      {:function, :f, 0, 1,
       [
         {:label, 1},
         {:line, 1},
         {:line, 2},
         {:line, 1},
         {:line, 0},
         {:debug_line, :none, 3, 44, 0}
       ]}

    {canonical, table} = Function.canonical(function, %{1 => 30, 2 => 10, 3 => 20}, %{})

    assert elem(canonical, 4) ==
             [
               {:label, 1},
               {:line, 3},
               {:line, 1},
               {:line, 3},
               {:line, 0},
               {:debug_line, :none, 2, 0, 0}
             ]

    assert table == %{1 => 1, 2 => 2, 3 => 3}

    assert Function.canonical(function, %{1 => 130, 2 => 110, 3 => 120}, %{}) ==
             {canonical, table}
  end

  test "unknown label operands preserve compiler numbering and relative lines" do
    function =
      {:function, :f, 0, 10,
       [{:label, 10}, {:line, 20}, {:unknown_hint, {:f, 99}}, {:jump, {:f, 10}}]}

    assert Function.canonical(function, %{20 => 100}, %{}) ==
             {{:function, :f, 0, 10,
               [{:label, 10}, {:line, 1}, {:unknown_hint, {:f, 99}}, {:jump, {:f, 10}}]},
              %{1 => 1}}
  end
end
