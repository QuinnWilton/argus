defmodule Argus.Extractor.ParamFlowReturnsTest do
  use ExUnit.Case, async: true

  alias Argus.Extractors.ParamFlow
  alias Argus.InstrId
  alias Argus.Test.Fixtures.ParamFlow.Returns

  setup_all do
    {:ok, facts} = Argus.Pipeline.extract([Returns], extractors: [ParamFlow])
    %{facts: facts}
  end

  defp sinks(facts, function) do
    func = InstrId.func_id(Returns, function, arity(function))

    facts
    |> Map.get(:sink_arg_derived, [])
    |> Enum.filter(fn [_id, caller, _pos, _param] -> caller == func end)
    |> Enum.map(fn [id, _func, pos, param] ->
      {id, String.to_integer(pos), String.to_integer(param)}
    end)
  end

  defp arity(function) when function in [:selected_capture, :captured_sites], do: 3

  defp arity(function)
       when function in [
              :selected,
              :recursive,
              :unknown_map,
              :captured_return,
              :combined_return,
              :reduced,
              :map_join
            ],
       do: 2

  defp arity(_function), do: 1

  defp params(facts, function),
    do: facts |> sinks(function) |> Enum.map(&elem(&1, 2)) |> Enum.sort()

  test "helper chains, remote self calls and recursive tails carry actual return data", %{
    facts: facts
  } do
    assert params(facts, :local) == [0]
    assert params(facts, :remote_self) == [0]
    assert params(facts, :recursive) == [0]
  end

  test "constant, stored and unknown returns do not inherit call arguments", %{facts: facts} do
    for function <- [:ignored, :lookup, :unknown_local_helper],
        do: assert(params(facts, function) == [])
  end

  test "summary substitution preserves argument positions and invocation sites", %{facts: facts} do
    assert params(facts, :selected) == [1]
    assert [{_id, 0, 0}] = sinks(facts, :sites)
  end

  test "mapping returns the callback's data and does not invent unknown callback flow", %{
    facts: facts
  } do
    assert params(facts, :mapped) == [0]
    assert params(facts, :external_map) == [0]
    assert params(facts, :external_unknown) == []
    assert params(facts, :erlang_map) == [0]
    assert params(facts, :constant_map) == []
    assert params(facts, :unknown_map) == []
  end

  test "callbacks preserve captured return data separately from collection elements", %{
    facts: facts
  } do
    assert params(facts, :captured_return) == [0]
    assert params(facts, :combined_return) == [0, 1]
    assert params(facts, :selected_capture) == [1]
    assert [{a, 0, 0}, {b, 0, 1}] = Enum.sort(sinks(facts, :captured_sites))
    assert a != b
  end

  test "reducers and joining retain their actual accumulator and separator data", %{facts: facts} do
    assert params(facts, :reduced) == [0, 1]
    assert params(facts, :constant_reduce) == []
    assert params(facts, :map_join) == [1]
  end

  test "the existing-atom choice marker survives a helper return", %{facts: facts} do
    func = InstrId.func_id(Returns, :chosen, 1)

    assert Enum.any?(facts.sink_arg_chosen, fn [_id, caller, pos] ->
             caller == func and pos == "0"
           end)
  end
end
