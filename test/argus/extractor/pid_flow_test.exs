defmodule Argus.Extractors.PidFlowTest do
  use ExUnit.Case, async: true
  alias Argus.Extractor.Terms
  alias Argus.Extractors.PidFlow
  alias Argus.Test.Fixtures.PidFlow, as: F

  doctest Argus.Extractors.PidFlow

  defp facts(modules) do
    {:ok, facts} = Argus.Pipeline.extract(modules, extractors: [PidFlow])

    Map.new(PidFlow.relations(), fn relation ->
      rows =
        for row <- Map.get(facts, relation, []),
            do: Enum.map(row, &String.replace(&1, "Argus.Test.Fixtures.PidFlow.", ""))

      {relation, rows}
    end)
  end

  # Rows with the site column dropped, for assertions that do not care
  # which instruction it is.
  defp unsited(rows), do: Enum.map(rows, &tl/1)

  describe "names" do
    # The registry side (ProcessRegistry) spells a name with Terms.spell/1;
    # a lookup must spell it the same, or the two never join: a key past
    # inspect's bounds carries a digest.
    test "a via or global name is spelled as the registry side spells it" do
      long = {:via, Registry, {:reg, String.duplicate("k", 5000)}}
      assert PidFlow.name_of(long) == Terms.spell(long)
      assert PidFlow.name_of(long) =~ " #"

      global = {:global, {:cache, String.duplicate("x", 5000)}}
      assert PidFlow.name_of(global) == Terms.spell(global)
    end
  end

  describe "allocation sites" do
    test "a proc_lib start or a monitoring spawn_opt returns the pid in its own shape" do
      [{_mod, bin}] =
        Code.compile_string("""
        defmodule Argus.PidFlowTest.Starts do
          def start(_owner) do
            helper = spawn(fn -> :ok end)
            {:ok, pid} = :proc_lib.start_link(__MODULE__, :init_it, [helper])
            send(pid, :go)
          end

          def watch(owner) do
            {pid, _ref} = :erlang.spawn_opt(__MODULE__, :init_it, [owner], [:monitor])
            send(pid, :go)
          end

          def init_it(_owner), do: :ok
        end
        """)

      {:ok, raw} = Argus.Pipeline.extract([bin], extractors: [PidFlow])
      starts = for [_id, func, proc, _kind, runs] <- raw.process_start, do: {func, proc, runs}

      starts = Enum.reject(starts, fn {_f, _p, runs} -> runs =~ "-fun-" end)

      for {func, runs} <- [
            {"Argus.PidFlowTest.Starts:start/1", "Argus.PidFlowTest.Starts:init_it/1"},
            {"Argus.PidFlowTest.Starts:watch/1", "Argus.PidFlowTest.Starts:init_it/1"}
          ] do
        assert [{^func, proc, ^runs}] = Enum.filter(starts, &(elem(&1, 0) == func))

        # The pid the send targets is the started process: the start's
        # result shape put it where the match reads it.
        assert Enum.any?(raw.pid_send, fn
                 [_id, f, _msg, "proc", ^proc] -> f == func
                 _ -> false
               end),
               "#{func} sends to #{proc}"
      end

      # The argument list reaches the spawned function's parameters: the
      # helper process is init_it's parameter 0.
      assert [
               _id,
               "Argus.PidFlowTest.Starts:start/1",
               "Argus.PidFlowTest.Starts:init_it/1",
               "0",
               "spawn" | _
             ] = Enum.find(raw[:pid_arg] || [], &match?([_, _, _, _, "spawn" | _], &1))
    end

    test "a spawn is named by its site and says what it runs; a server start its module" do
      f = facts([F.Worker, F.Owner, F.Loops])

      assert ["Loops:start/0", "spawn Loops:start/0#10", "spawn", "Loops:loop/0"] in unsited(
               f.process_start
             )

      assert [
               "Loops:start/0",
               "spawn Loops:start/0#22",
               "spawn",
               "Loops:-start/0-fun-0-/1"
             ] in unsited(f.process_start)

      assert ["Owner:direct/0", "server Owner:direct/0#8", "server", "Worker"] in unsited(
               f.process_start
             )

      assert [
               "Worker:start_link/1",
               "server Worker:start_link/1#6",
               "server",
               "Worker"
             ] in unsited(f.process_start)
    end

    test "the site column is the start instruction" do
      f = facts([F.Loops])

      assert ["Loops:start/0#10", "Loops:start/0" | _] =
               Enum.find(
                 f.process_start,
                 &(Enum.at(&1, 3) == "spawn" and Enum.at(&1, 4) == "Loops:loop/0")
               )
    end

    test "a computed module, apply and a library pid start nothing" do
      f = facts([F.Quiet])
      assert f.process_start == []
      assert f.pid_call == []
      assert f.pid_send == []
    end
  end

  describe "terms that hold pids" do
    test "a start returns its process in {:ok, pid}" do
      f = facts([F.Worker])
      assert ["Worker:start_link/1", "Worker:start_link/1#6", "tuple", ":ok", "2"] in f.pid_object

      assert [
               "Worker:start_link/1",
               "Worker:start_link/1#6",
               "{1}",
               "proc",
               "server Worker:start_link/1#6"
             ] in f.pid_field

      assert ["Worker:start_link/1", "obj", "Worker:start_link/1#6"] in f.pid_return
    end

    test "a state map keeps each pid under its own key" do
      f = facts([F.Front])
      [obj] = for ["Front:init/1", o, "map", _, _] <- f.pid_object, do: o

      fields = for ["Front:init/1", ^obj, sel, kind, _src] <- f.pid_field, do: {sel, kind}
      assert Enum.sort(fields) == [{":back", "load"}, {":side", "load"}]
    end

    test "a read of one state field is a load of that field" do
      f = facts([F.Front])

      assert Enum.any?(
               f.pid_load,
               &match?(["Front:handle_call/3", _, ":back", "param", "2"], &1)
             )

      refute Enum.any?(f.pid_load, &match?(["Front:handle_call/3", _, ":side" | _], &1))
    end

    test "an update keeps the fields it does not set, and a cons cell its tail" do
      f = facts([F.Relay])
      [update] = for ["Relay:handle_cast/2", o, "map", _, _] <- f.pid_object, do: o
      [cons] = for ["Relay:handle_cast/2", o, "list", _, _] <- f.pid_object, do: o

      assert ["Relay:handle_cast/2", update, "param", "1"] in f.pid_base
      assert [update, ":subs"] in f.pid_sets
      assert ["Relay:handle_cast/2", update, ":subs", "obj", cons] in f.pid_field
      assert Enum.any?(f.pid_field, &match?(["Relay:handle_cast/2", ^cons, "[]", "load", _], &1))
      assert Enum.any?(f.pid_base, &match?(["Relay:handle_cast/2", ^cons, "load", _], &1))
    end

    test "a message tuple carries the pid in its field" do
      f = facts([F.Hub])
      [msg] = for ["Hub:subscribe/1", o, "tuple", ":subscribe", "2"] <- f.pid_object, do: o
      assert ["Hub:subscribe/1", msg, "{1}", "param", "0"] in f.pid_field
      assert Enum.any?(f.pid_message, &match?([_, "Hub:subscribe/1", "cast", "obj", ^msg], &1))
    end
  end

  describe "summaries" do
    test "a wrapper's result is a site; pid_result names the callee" do
      f = facts([F.Owner])
      [site] = for [s, "Owner:run/0", "Worker:start_link/1"] <- f.pid_result, do: s
      assert Enum.any?(f.pid_load, &match?(["Owner:run/0", _, "{1}", "result", ^site], &1))

      assert ["Owner:hand_off/1", "Owner:relay/1", "0", "call", "param", "0"] in unsited(
               f.pid_arg
             )
    end

    test "a server start's init argument reaches init/1" do
      assert ["Worker:start_link/1", "Worker:init/1", "0", "init", "param", "0"] in unsited(
               facts([F.Worker]).pid_arg
             )

      assert ["CycleA:init/1", "CycleB:start_link/1", "0", "call", "self", "self"] in unsited(
               facts([F.CycleA]).pid_arg
             )
    end

    test "a call's target survives being parked across another call" do
      f = facts([F.Owner])

      assert [
               "Owner:across_a_call/0",
               "call",
               "proc",
               "server Owner:across_a_call/0#9"
             ] in unsited(f.pid_call)
    end

    test "a call's target survives the trim that renumbers its slot" do
      calls = unsited(facts([F.Owner]).pid_call)

      assert ["Owner:across_a_trim/0", "call", "proc", "server Owner:across_a_trim/0#15"] in calls
      assert ["Owner:across_a_trim/0", "call", "proc", "server Owner:across_a_trim/0#9"] in calls

      assert Enum.count(calls, &match?(["Owner:across_a_trim/0" | _], &1)) == 2
    end

    test "an API function's call and cast target its parameter" do
      f = facts([F.Worker])
      assert ["Worker:ping/1", "call", "param", "0"] in unsited(f.pid_call)
      assert ["Worker:notify/1", "cast", "param", "0"] in unsited(f.pid_call)
    end

    test "register stores a pid under a name; a send reads a name or a captured pid" do
      f = facts([F.Loops])

      assert ["Loops:start/0", ":loops", "proc", "spawn Loops:start/0#10"] in unsited(
               f.pid_register
             )

      assert Enum.any?(f.pid_send, &match?([_, "Loops:start/0", ":tick", "name", ":loops"], &1))

      assert Enum.any?(
               f.pid_send,
               &match?([_, "Loops:-start/0-fun-0-/1", "{:done, …}", "param", "0"], &1)
             )

      assert [
               "Loops:start/0",
               "Loops:-start/0-fun-0-/1",
               "0",
               "closure",
               "proc",
               "spawn Loops:start/0#10"
             ] in unsited(f.pid_arg)
    end

    test "a supervisor's start_child starts the child spec's module" do
      f = facts([F.Owner])

      assert ["Owner:dynamic/0", "server Owner:dynamic/0#8", "server", "Worker"] in unsited(
               f.process_start
             )
    end

    test "a literal target is a name" do
      f = facts([F.Hub, F.Listener])
      assert ["Hub:subscribe/1", "cast", "name", "Hub"] in unsited(f.pid_call)

      assert ["Listener:init/1", "Hub:subscribe/1", "0", "call", "self", "self"] in unsited(
               f.pid_arg
             )
    end

    test "a send is also an info call" do
      f = facts([F.Loops])
      assert ["Loops:start/0", "info", "name", ":loops"] in unsited(f.pid_call)
      assert ["Loops:-start/0-fun-0-/1", "info", "param", "0"] in unsited(f.pid_call)
    end

    test "spawn/4 passes its argument list, after the node, to what it runs" do
      f = facts([F.Starts])

      assert ["Starts:remote/0", "Starts:relay/1", "0", "spawn", "self", "self"] in unsited(
               f.pid_arg
             )
    end

    test "a start with a literal name registers its process; so do register_name and Registry" do
      f = facts([F.Names, F.Starts])
      registers = unsited(f.pid_register)

      assert ["Names:start_link/1", "{:global, :names}", "proc", "server Names:start_link/1#7"] in registers
      assert ["Names:init/1", "{:via, Registry, {Reg, :names}}", "self", "self"] in registers
      assert ["Starts:agent/0", ":counter", "proc", "agent Starts:agent/0#8"] in registers
    end

    test "lookups name the registry the name lives in" do
      f = facts([F.Names])
      calls = unsited(f.pid_call)

      assert ["Names:ping_global/0", "call", "name", "{:global, :names}"] in calls
      assert ["Names:ping_whereis/0", "call", "name", "{:global, :names}"] in calls
      assert ["Names:ping_registry/0", "call", "name", "{:via, Registry, {Reg, :names}}"] in calls
    end

    test "an exit signal, a monitor and a link name their target" do
      f = facts([F.Keeper])
      signals = unsited(f.pid_signal)

      assert Enum.any?(signals, &match?(["Keeper:handle_cast/2", "exit", "load", _], &1))
      assert ["Keeper:stop/1", "exit", "param", "0"] in signals
      assert Enum.any?(signals, &match?(["Keeper:init/1", "monitor", "proc", "spawn " <> _], &1))
    end

    test "the compiler's generated functions emit nothing" do
      for {_relation, rows} <- facts([F.Worker, F.Loops]), row <- rows do
        refute Enum.any?(row, &String.contains?(&1, ["__info__", "module_info"])), inspect(row)
      end
    end
  end
end
