defmodule Argus.Extractor.ParamFlowTest do
  use ExUnit.Case, async: true

  alias Argus.Extractors.ParamFlow

  alias Argus.Test.Fixtures.ParamFlow.Shapes

  setup_all do
    {:ok, facts} = Argus.Pipeline.extract([Shapes], extractors: [ParamFlow])
    %{facts: facts}
  end

  defp derived(facts, func_fragment) do
    for [caller, callee, pos, param] <- Map.get(facts, :call_arg_derived, []),
        String.contains?(caller, func_fragment),
        do: {short(callee), String.to_integer(pos), String.to_integer(param)}
  end

  defp sinks(facts, func_fragment) do
    for [_id, func, pos, param] <- Map.get(facts, :sink_arg_derived, []),
        String.contains?(func, func_fragment),
        do: {String.to_integer(pos), String.to_integer(param)}
  end

  defp short(callee), do: callee |> String.split(":") |> List.last()

  test "a trim renumbers the frame slot by slot, without mixing the slots", %{facts: facts} do
    assert {"atom_to_list/1", 0, 1} in derived(facts, "trimmed/3")
    assert {"binary_to_list/1", 0, 2} in derived(facts, "trimmed/3")
    refute {"atom_to_list/1", 0, 2} in derived(facts, "trimmed/3")
    refute {"binary_to_list/1", 0, 1} in derived(facts, "trimmed/3")
  end

  test "a binary built from the parameter reaches the sink", %{facts: facts} do
    assert sinks(facts, "concat/1") == [{0, 0}]
  end

  test "a parameter carried around a receive loop reaches the sink after it", %{facts: facts} do
    assert sinks(facts, "looped/1") == [{0, 0}]
  end

  test "a binary pattern in the head reaches the sink", %{facts: facts} do
    assert sinks(facts, "bin/1") == [{0, 0}]
  end

  test "head destructuring of a map reaches the sink", %{facts: facts} do
    assert sinks(facts, "head/2") == [{0, 0}]
  end

  test "a later clause is not blind to its own parameters", %{facts: facts} do
    assert sinks(facts, "second/3") == [{0, 1}]
  end

  test "a decoder hands the request through; Map.get keeps it", %{facts: facts} do
    assert sinks(facts, "decoded/1") == [{0, 0}]
  end

  # :maps.get(Key, Map): the result is the map's data, not the key's.
  test "a direct :maps.get hands its map through, not its key", %{facts: facts} do
    assert sinks(facts, "direct_get/1") == [{0, 0}]
    assert sinks(facts, "keyed/2") == []
  end

  test "a value loaded by an unknown callee is fresh", %{facts: facts} do
    assert sinks(facts, "loaded/1") == []
    assert {"load/1", 0, 0} in derived(facts, "loaded/1")
  end

  test "forwarding records which parameter feeds which position", %{facts: facts} do
    assert Enum.sort(derived(facts, "forwarded/2")) == [{"helper/2", 0, 1}, {"helper/2", 1, 0}]
  end

  test "a captured variable is a parameter of the closure", %{facts: facts} do
    rows = derived(facts, "captured/2")

    assert Enum.any?(rows, fn {callee, pos, param} ->
             callee =~ "captured" and pos == 1 and param == 0
           end)
  end

  test "a literal argument derives from nothing", %{facts: facts} do
    assert sinks(facts, "literal/1") == []
  end

  test "a closure a higher-order call runs takes the element as its first parameter" do
    {:ok, facts} =
      Argus.Pipeline.extract([Argus.Test.Fixtures.Taint.HofElement], extractors: [ParamFlow])

    assert Enum.any?(facts.call_arg_derived, fn
             [caller, closure, "0", "1"] ->
               caller =~ "HofElement:handle_event/3" and closure =~ "-handle_event/3-fun-0-"

             _ ->
               false
           end)
  end
end
