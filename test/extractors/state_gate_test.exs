defmodule Argus.Extractors.StateGateTest do
  @moduledoc """
  What `Argus.Extractors.StateGate` reads of a GenServer handler's state
  gates, asked at the monitor each fixture of
  test/fixtures/soundness/gated_once_fixture.ex takes: the atoms the
  gate admits there (`state_gate`), whether every way on sets the field
  outside them (`gate_closed`), and what the module's returns set it to
  (`state_return`).
  """
  use ExUnit.Case, async: true

  alias Argus.Extractors.StateGate
  alias Argus.Test.Soundness.Gated, as: G

  defp facts(mod) do
    {:ok, data} = BeamSpy.BeamFile.disassemble(to_string(:code.which(mod)))
    {data, StateGate.extract(data)}
  end

  # The sites of `erlang:monitor/2` in the module, as instruction ids.
  defp monitor_sites(data) do
    for {:function, name, arity, _entry, instrs} <- data.functions,
        {{:call_ext, 2, {:extfunc, :erlang, :monitor, 2}}, idx} <- Enum.with_index(instrs),
        do: "#{Argus.Pipeline.Normalize.func_id(data.module, name, arity)}##{idx}"
  end

  # {admitted atoms, closed?} per key at the module's monitor.
  defp at_monitor(mod) do
    {data, facts} = facts(mod)
    [site] = monitor_sites(data)

    gates =
      for [^site, _func, key, value] <- Map.get(facts, :state_gate, []),
          reduce: %{},
          do: (acc -> Map.update(acc, key, [value], &Enum.sort([value | &1])))

    closed = for [^site, _func, key] <- Map.get(facts, :gate_closed, []), do: key
    Map.new(gates, fn {key, values} -> {key, {values, key in closed}} end)
  end

  defp returns(mod) do
    {_data, facts} = facts(mod)

    facts
    |> Map.get(:state_return, [])
    |> Enum.map(fn [func, key, value] ->
      {func |> String.split(":") |> List.last(), key, value}
    end)
    |> Enum.sort()
  end

  describe "the gate" do
    test "a map field in the clause head admits its literal" do
      assert at_monitor(G.Flag) == %{":attached" => {["false"], true}}
    end

    test "a truthiness test admits nil and false" do
      assert at_monitor(G.NilOwner) == %{":owner" => {["false", "nil"], true}}
    end

    test "a case on the field admits the arm's atom" do
      assert at_monitor(G.Status) == %{":status" => {[":idle"], true}}
    end

    test "an Erlang record's field, by its tuple position" do
      assert at_monitor(:gated_record) == %{"{1}" => {[":undefined"], true}}
    end

    test "no gate before the test, on a nested field, on Map.get/2, or on the message" do
      for mod <- [G.MonitorBeforeTest, G.NestedField, G.MapGet, G.MessageField] do
        assert at_monitor(mod) == %{}, inspect(mod)
      end
    end
  end

  describe "closed" do
    test "a literal, a helper's literal, a stop, the caller in from" do
      for mod <- [G.ClosedByHelper, G.ClosedByStop] do
        assert at_monitor(mod) == %{":attached" => {["false"], true}}, inspect(mod)
      end

      assert at_monitor(G.ClaimedByCaller) == %{":worker" => {["nil"], true}}
    end

    test "not by another field, one way out, a throw, a rescue, the message's value" do
      for mod <- [G.OtherField, G.SomeReturns, G.Throws, G.RescueKeeps, G.MessageValue] do
        assert at_monitor(mod) == %{":attached" => {["false"], false}}, inspect(mod)
      end
    end
  end

  describe "state_return" do
    test "what the handlers set, through helpers and code_change/3" do
      assert returns(G.Flag) == [{"handle_cast/2", ":attached", "true"}]
      assert {"handle_info/2", ":attached", "false"} in returns(G.ResetThroughHelper)
      assert {"handle_info/2", ":attached", "false"} in returns(G.ResetByTailCall)
      assert {"code_change/3", ":attached", "false"} in returns(G.ResetInCodeChange)
    end

    test "a value no atom is, and any value" do
      assert returns(G.NilOwner) == [{"handle_cast/2", ":owner", "nonatom"}]
      assert returns(G.ClaimedByCaller) == [{"handle_call/3", ":worker", "nonatom"}]
      assert {"handle_call/3", ":attached", "dynamic"} in returns(G.StateReplaced)
      assert {"handle_call/3", ":attached", "dynamic"} in returns(G.ResetFromMessage)
      assert {"handle_cast/2", ":attached", "dynamic"} in returns(G.Throws)
    end

    test "a stop, and terminate/2, set nothing" do
      assert returns(G.ClosedByStop) == []
      assert returns(G.ResetInTerminate) == [{"handle_cast/2", ":attached", "true"}]
    end
  end
end
