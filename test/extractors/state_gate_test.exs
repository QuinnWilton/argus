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
  alias Argus.Pipeline.Normalize
  alias Argus.Test.Soundness.Gated, as: G
  alias Argus.Test.Soundness.RacesOrder

  defp facts(mod) do
    {:ok, data} = BeamSpy.BeamFile.disassemble(to_string(:code.which(mod)))
    {data, StateGate.extract(data)}
  end

  # The sites of `erlang:monitor/2` in the module, as instruction ids.
  defp monitor_sites(data) do
    for {:function, name, arity, _entry, instrs} <- data.functions,
        {{:call_ext, 2, {:extfunc, :erlang, :monitor, 2}}, idx} <- Enum.with_index(instrs),
        do: "#{Normalize.func_id(data.module, name, arity)}##{idx}"
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
    |> Enum.map(fn [func, _clause, key, value] ->
      {func |> String.split(":") |> List.last(), key, value}
    end)
    |> Enum.reject(&match?({"init/1", _, _}, &1))
    |> Enum.uniq()
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

  # The rows of a relation for one module, the module's name dropped from
  # the function and site ids.
  defp rows(mod, relation) do
    {_data, facts} = facts(mod)

    facts
    |> Map.get(relation, [])
    |> Enum.map(fn row -> Enum.map(row, &short/1) end)
    |> Enum.sort()
  end

  defp short(id), do: id |> String.split(":") |> List.last()

  describe "state_return: the clause, and the start" do
    test "a return is the clause's its message's tag names, and init/1's is the start" do
      rows = rows(RacesOrder.Trie, :state_return)

      assert ["handle_info/2", "loaded", "status", "ready"] in rows
      assert ["init/1", "*", "status", "init"] in rows
      refute Enum.any?(rows, &match?(["handle_call/3" | _], &1))
    end
  end

  describe "state_excluded" do
    test "a clause after the one for the start's value does not run while the field holds it" do
      trie = RacesOrder.Trie
      {data, facts} = facts(trie)

      bump_calls =
        for {:function, :handle_call, 3, _entry, instrs} <- data.functions,
            {{:call, 2, {^trie, :bump, 2}}, idx} <- Enum.with_index(instrs),
            do: "#{Normalize.func_id(trie, :handle_call, 3)}##{idx}"

      assert [site] = bump_calls

      assert [^site, _func, ":status", ":init"] =
               Enum.find(facts[:state_excluded], &match?([^site | _], &1))
    end

    test "a record's shape holds when its field holds a value" do
      # vernemq's tries serve an update in a clause that takes any state,
      # after one for `#state{status = init}`: past the record test, the
      # serving clause is reached only by a state that is no such record,
      # which it always is. The test hook, which takes any status, is not
      # excluded.
      {data, facts} = facts(:handoff_trie)

      bumps =
        for {:function, :handle_call, 3, _entry, instrs} <- data.functions,
            {{:call, 2, {:handoff_trie, :bump, 2}}, idx} <- Enum.with_index(instrs),
            do: "#{Normalize.func_id(:handoff_trie, :handle_call, 3)}##{idx}"

      excluded = for [site, _func, "{1}", ":init"] <- facts[:state_excluded], do: site

      assert length(bumps) == 2
      assert Enum.count(bumps, &(&1 in excluded)) == 1
    end

    test "a gate's own site is not excluded for the value it admits" do
      for [_site, _func, key, value] <- rows(G.Flag, :state_excluded) do
        refute {key, value} == {":attached", "false"}
      end
    end
  end
end
