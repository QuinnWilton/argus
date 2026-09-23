defmodule Argus.Extractors.PidFlowTest do
  use ExUnit.Case, async: true

  alias Argus.Extractors.PidFlow
  alias Argus.Test.Fixtures.PidFlow, as: F

  defp facts(modules) do
    {:ok, facts} = Argus.Pipeline.extract(modules, extractors: [PidFlow])

    Map.new(PidFlow.relations(), fn relation ->
      rows =
        for row <- Map.get(facts, relation, []),
            do: Enum.map(row, &String.replace(&1, "Argus.Test.Fixtures.PidFlow.", ""))

      {relation, rows}
    end)
  end

  describe "allocation sites" do
    test "a spawn is named by what it runs, a server start by its module" do
      f = facts([F.Worker, F.Owner, F.Loops])

      assert ["Loops:start/0", "spawn Loops:loop/0", "spawn", "Loops:loop/0"] in f.process_start

      assert [
               "Loops:start/0",
               "spawn Loops:-start/0-fun-0-/1",
               "spawn",
               "Loops:-start/0-fun-0-/1"
             ] in f.process_start

      assert ["Owner:direct/0", "server Worker", "server", "Worker"] in f.process_start
      assert ["Worker:start_link/1", "server Worker", "server", "Worker"] in f.process_start
    end

    test "a computed module, apply and a library pid start nothing" do
      f = facts([F.Quiet])
      assert f.process_start == []
      assert f.pid_call == []
      assert f.pid_send == []
    end
  end

  describe "summaries" do
    test "a wrapper returns the process its tail call starts" do
      assert ["Worker:start_link/1", "proc", "server Worker"] in facts([F.Worker]).pid_return
    end

    test "a wrapper's result and a parameter flow on as arguments" do
      f = facts([F.Owner])
      assert ["Owner:run/0", "Worker:ping/1", "0", "result", "Worker:start_link/1"] in f.pid_arg
      assert ["Owner:hand_off/1", "Owner:relay/1", "0", "param", "0"] in f.pid_arg
    end

    test "a server start's init argument reaches init/1" do
      assert ["Worker:start_link/1", "Worker:init/1", "0", "param", "0"] in facts([F.Worker]).pid_arg

      assert ["CycleA:init/1", "CycleB:start_link/1", "0", "self", "self"] in facts([F.CycleA]).pid_arg
    end

    test "a call's target survives being parked across another call" do
      f = facts([F.Owner])
      assert ["Owner:across_a_call/0", "call", "proc", "server Worker"] in f.pid_call
      assert ["Owner:direct/0", "call", "proc", "server Worker"] in f.pid_call
    end

    test "an API function's call and cast target its parameter" do
      f = facts([F.Worker])
      assert ["Worker:ping/1", "call", "param", "0"] in f.pid_call
      assert ["Worker:notify/1", "cast", "param", "0"] in f.pid_call
    end

    test "register stores a pid under a name; a send reads a name or a captured pid" do
      f = facts([F.Loops])
      assert ["Loops:start/0", ":loops", "proc", "spawn Loops:loop/0"] in f.pid_register

      assert Enum.any?(f.pid_send, &match?([_, "Loops:start/0", ":tick", "name", ":loops"], &1))

      assert Enum.any?(
               f.pid_send,
               &match?([_, "Loops:-start/0-fun-0-/1", "{:done, …}", "param", "0"], &1)
             )

      assert ["Loops:start/0", "Loops:-start/0-fun-0-/1", "0", "proc", "spawn Loops:loop/0"] in f.pid_arg
    end

    test "the compiler's generated functions emit nothing" do
      for {_relation, rows} <- facts([F.Worker, F.Loops]), row <- rows do
        refute Enum.any?(row, &String.contains?(&1, ["__info__", "module_info"])), inspect(row)
      end
    end
  end
end
