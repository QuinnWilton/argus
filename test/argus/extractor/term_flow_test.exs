defmodule Argus.Extractors.TermFlowTest do
  use ExUnit.Case, async: true
  alias Argus.Extractor.Terms
  alias Argus.Extractors.TermFlow
  alias Argus.Test.Fixtures.PidFlow, as: F

  doctest Argus.Extractors.TermFlow

  defp facts(modules) do
    {:ok, facts} = Argus.Pipeline.extract(modules, extractors: [TermFlow])

    Map.new(TermFlow.relations(), fn relation ->
      rows =
        for row <- Map.get(facts, relation, []),
            do: Enum.map(row, &String.replace(&1, "Argus.Test.Fixtures.PidFlow.", ""))

      {relation, rows}
    end)
  end

  # Rows with the site column dropped, for assertions that do not care
  # which instruction it is.
  defp unsited(rows), do: Enum.map(rows, &tl/1)

  test "a function using float registers beside a tuple match is extracted" do
    [{_mod, bin}] =
      Code.compile_string("""
      defmodule Argus.TermFlowTest.Floats do
        def scaled({:ok, x}, factor) when is_float(x) and is_float(factor), do: {:ok, x * factor + 1.0}
        def scaled(other, _factor), do: other
      end
      """)

    {:beam_file, _, _, _, _, code} = :beam_disasm.file(bin)
    assert inspect(code, limit: :infinity) =~ "{:fr, "

    {:ok, raw} = Argus.Pipeline.extract([bin], extractors: [TermFlow])
    assert Map.get(raw, :extraction_error, []) == []
    assert ["Argus.TermFlowTest.Floats:scaled/2", "param", "0"] in raw.return_var
  end

  test "map read defaults and compound literal keys retain general value provenance" do
    [{_mod, bin}] =
      Code.compile_string("""
      defmodule Argus.TermFlowTest.Values do
        def elixir_default(map, fallback), do: Map.get(map, :missing, fallback)
        def erlang_default(map, fallback), do: :maps.get(:missing, map, fallback)
        def access_default(map, fallback), do: Access.get(map, :missing, fallback)
        def sent(target, message), do: send(target, message)
        def dictionary_field, do: Process.get(:container).owner
        def compound(value) do
          map = Map.put(%{}, {:compound, 1.5}, value)
          Map.fetch!(map, {:compound, 1.5})
        end
        def overwritten(value) do
          map = Map.put(%{}, :key, value)
          map = Map.put(map, :key, :constant)
          Map.fetch!(map, :key)
        end
        def unrelated(left, right) do
          map = %{left: left, right: right}
          Map.fetch!(map, :left)
        end
      end
      """)

    {:ok, raw} = Argus.Pipeline.extract([bin], extractors: [TermFlow])

    for function <- ["elixir_default", "erlang_default", "access_default"] do
      assert ["Argus.TermFlowTest.Values:#{function}/2", "param", "1"] in raw.return_var
    end

    assert ["Argus.TermFlowTest.Values:sent/2", "param", "1"] in raw.return_var
    refute ["Argus.TermFlowTest.Values:sent/2", "param", "0"] in raw.return_var

    assert Enum.any?(
             raw.field_load,
             &match?(
               [
                 "Argus.TermFlowTest.Values:dictionary_field/0",
                 _,
                 ":owner",
                 "dictionary",
                 ":container"
               ],
               &1
             )
           )

    assert ["Argus.TermFlowTest.Values:compound/1", "param", "0"] in raw.return_var

    # The overwrite shadows the parameter: what is read back is the literal.
    assert ["Argus.TermFlowTest.Values:overwritten/1", "literal", ":constant"] in raw.return_var
    refute ["Argus.TermFlowTest.Values:overwritten/1", "param", "0"] in raw.return_var

    assert ["Argus.TermFlowTest.Values:unrelated/2", "param", "0"] in raw.return_var
    refute ["Argus.TermFlowTest.Values:unrelated/2", "param", "1"] in raw.return_var
  end

  describe "names" do
    # The registry side (ProcessRegistry) spells a name with Terms.spell/1;
    # a lookup must spell it the same, or the two never join: a key past
    # inspect's bounds carries a digest.
    test "a via or global name is spelled as the registry side spells it" do
      long = {:via, Registry, {:reg, String.duplicate("k", 5000)}}
      assert TermFlow.name_of(long) == Terms.spell(long)
      assert TermFlow.name_of(long) =~ " #"

      global = {:global, {:cache, String.duplicate("x", 5000)}}
      assert TermFlow.name_of(global) == Terms.spell(global)
    end
  end

  describe "allocation sites" do
    test "a proc_lib start or a monitoring spawn_opt returns the pid in its own shape" do
      [{_mod, bin}] =
        Code.compile_string("""
        defmodule Argus.TermFlowTest.Starts do
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

      {:ok, raw} = Argus.Pipeline.extract([bin], extractors: [TermFlow])
      starts = for [_id, func, proc, _kind, runs] <- raw.process_start, do: {func, proc, runs}

      starts = Enum.reject(starts, fn {_f, _p, runs} -> runs =~ "-fun-" end)

      for {func, runs} <- [
            {"Argus.TermFlowTest.Starts:start/1", "Argus.TermFlowTest.Starts:init_it/1"},
            {"Argus.TermFlowTest.Starts:watch/1", "Argus.TermFlowTest.Starts:init_it/1"}
          ] do
        assert [{^func, proc, ^runs}] = Enum.filter(starts, &(elem(&1, 0) == func))

        # The pid the send targets is the started process: the start's
        # result shape put it where the match reads it.
        assert Enum.any?(raw.process_send_var, fn
                 [_id, f, _msg, "process", ^proc] -> f == func
                 _ -> false
               end),
               "#{func} sends to #{proc}"
      end

      # The argument list reaches the spawned function's parameters: the
      # helper process is init_it's parameter 0.
      assert [
               _id,
               "Argus.TermFlowTest.Starts:start/1",
               "Argus.TermFlowTest.Starts:init_it/1",
               "0",
               "spawn" | _
             ] = Enum.find(raw[:call_arg_var] || [], &match?([_, _, _, _, "spawn" | _], &1))
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

    test "a GenStage start is a server start of its module" do
      alias Argus.Test.Fixtures.PartialInfoStage

      rows = facts([PartialInfoStage])[:process_start]

      assert Enum.any?(
               rows,
               &match?(
                 [_site, _func, _proc, "server", "Argus.Test.Fixtures.PartialInfoStage"],
                 &1
               )
             )
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
      assert f.process_call_var == []
      assert f.process_send_var == []
    end
  end

  describe "the process dictionary" do
    alias Argus.Test.Fixtures.Dictionary

    defp dict_facts(modules) do
      {:ok, facts} = Argus.Pipeline.extract(modules, extractors: [TermFlow])

      Map.new([:dictionary_operation, :dictionary_put, :table_use, :return_var], fn relation ->
        rows =
          for row <- Map.get(facts, relation, []),
              do: Enum.map(row, &String.replace(&1, "Argus.Test.Fixtures.Dictionary.", ""))

        {relation, rows}
      end)
    end

    test "every put, read and erase, with its literal key" do
      r = dict_facts([Dictionary.TmpOptions])
      ops = for [_id, func, op, key] <- r.dictionary_operation, uniq: true, do: {func, op, key}

      assert {"TmpOptions:create_tmp/0", "put", ":dict_options"} in ops
      assert {"TmpOptions:get_tmp/0", "get", ":dict_options"} in ops
      assert {"TmpOptions:delete_tmp/0", "erase", ":dict_options"} in ops
    end

    test "a put keeps its value under the key, and a read hands it back" do
      r = dict_facts([Dictionary.TmpOptions])

      assert [[_, "TmpOptions:create_tmp/0", ":dict_options", "table", "table " <> site]] =
               r.dictionary_put

      assert site =~ "TmpOptions:create_tmp/0#"
      assert ["TmpOptions:get_tmp/0", "dictionary", ":dict_options"] in r.return_var
    end

    test "a key computed at run time is a key not known, and keeps nothing" do
      r = dict_facts([Dictionary.ComputedKey])
      ops = for [_id, func, op, key] <- r.dictionary_operation, uniq: true, do: {func, op, key}

      assert {"ComputedKey:run/2", "put", "dynamic"} in ops
      assert {"ComputedKey:run/2", "get", "dynamic"} in ops
      assert {"ComputedKey:run_literal/1", "put", "{:computed, :fixed}"} in ops
      assert for([_, "ComputedKey:run/2" | _] <- r.dictionary_put, do: :row) == []

      assert [_, "ComputedKey:run_literal/1", "dictionary", "{:computed, :fixed}"] =
               Enum.find(r.table_use, &match?([_, "ComputedKey:run_literal/1" | _], &1))
    end
  end

  describe "terms that hold pids" do
    test "a start returns its process in {:ok, pid}" do
      f = facts([F.Worker])

      assert ["Worker:start_link/1", "Worker:start_link/1#6", "tuple", ":ok", "2"] in f.term_allocation

      assert [
               "Worker:start_link/1",
               "Worker:start_link/1#6",
               "{1}",
               "process",
               "server Worker:start_link/1#6"
             ] in f.field_store

      assert ["Worker:start_link/1", "term", "Worker:start_link/1#6"] in f.return_var
    end

    test "a state map keeps each pid under its own key" do
      f = facts([F.Front])
      [obj] = for ["Front:init/1", o, "map", _, _] <- f.term_allocation, do: o

      fields = for ["Front:init/1", ^obj, sel, kind, _src] <- f.field_store, do: {sel, kind}
      assert Enum.sort(fields) == [{":back", "load"}, {":side", "load"}]
    end

    test "a read of one state field is a load of that field" do
      f = facts([F.Front])

      assert Enum.any?(
               f.field_load,
               &match?(["Front:handle_call/3", _, ":back", "param", "2"], &1)
             )

      refute Enum.any?(f.field_load, &match?(["Front:handle_call/3", _, ":side" | _], &1))
    end

    test "an update keeps the fields it does not set, and a cons cell its tail" do
      f = facts([F.Relay])
      [update] = for ["Relay:handle_cast/2", o, "map", _, _] <- f.term_allocation, do: o
      [cons] = for ["Relay:handle_cast/2", o, "list", _, _] <- f.term_allocation, do: o

      assert ["Relay:handle_cast/2", update, "param", "1"] in f.term_update_base
      assert [update, ":subs"] in f.term_update_overwrites
      assert ["Relay:handle_cast/2", update, ":subs", "term", cons] in f.field_store

      assert Enum.any?(
               f.field_store,
               &match?(["Relay:handle_cast/2", ^cons, "[]", "load", _], &1)
             )

      assert Enum.any?(f.term_update_base, &match?(["Relay:handle_cast/2", ^cons, "load", _], &1))
    end

    test "a tuple element read after a match carries the shape the match tested" do
      f = facts([F.Matches])
      shapes = for [load, tag, arity] <- f.field_load_match, do: {load, tag, arity}

      # is_tagged_tuple tests the tag and the arity at once...
      assert Enum.any?(shapes, &match?({"Matches:tagged/1#" <> _, ":cont", "2"}, &1))
      # ...select_tuple_arity the arity alone, each arm its own.
      assert Enum.any?(shapes, &match?({"Matches:selected/1#" <> _, "", "2"}, &1))
      assert Enum.any?(shapes, &match?({"Matches:selected/1#" <> _, "", "3"}, &1))

      for {"Matches:" <> _ = load, _tag, _arity} <- shapes do
        assert Enum.any?(f.field_load, &match?([_, ^load | _], &1))
      end
    end

    test "a keyword lookup with a literal key reads the pairs under that key" do
      f = facts([F.Options])

      shapes =
        for ["Options:ping/1" <> _ = load, tag, arity] <- f.field_load_match,
            do: {load, tag, arity}

      assert Enum.any?(shapes, &match?({_, ":left", "2"}, &1))
      assert Enum.any?(shapes, &match?({_, ":right", "2"}, &1))
    end

    test "a tuple handed back past a match of another tag is not the term the match failed on" do
      f = facts([F.Refused])

      refute Enum.any?(f.return_var, &match?(["Refused:start/0", "term", _], &1))
    end

    test "a message tuple carries the pid in its field" do
      f = facts([F.Hub])
      [msg] = for ["Hub:subscribe/1", o, "tuple", ":subscribe", "2"] <- f.term_allocation, do: o
      assert ["Hub:subscribe/1", msg, "{1}", "param", "0"] in f.field_store

      assert Enum.any?(
               f.process_message_var,
               &match?([_, "Hub:subscribe/1", "cast", "term", ^msg], &1)
             )
    end
  end

  # Compiled once, with the test module: the tests below share it.
  @literals_beam (fn ->
                    [{_mod, bin}] =
                      Code.compile_string("""
                      defmodule Argus.TermFlowTest.Literals do
                        def hand, do: take(:alpha, "beta", 7, true)
                        def take(a, b, c, d), do: {a, b, c, d}
                        def name, do: :cache
                        def flag, do: false
                        def stored(pid), do: %{pid: pid, mode: :fast}
                        def logged(log, pid) do
                          log.(:hint)
                          log.(pid)
                        end
                        def either(pick), do: if(pick, do: :left, else: :right)
                      end
                      """)

                    bin
                  end).()

  describe "literals" do
    setup do
      bin = @literals_beam
      {:ok, raw} = Argus.Pipeline.extract([bin], extractors: [TermFlow])
      %{raw: raw, m: "Argus.TermFlowTest.Literals"}
    end

    test "an atom, a binary or an integer handed to a call is a literal", %{raw: raw, m: m} do
      hand = m <> ":hand/0"
      args = for [_, ^hand, _, pos, "call", kind, var] <- raw.call_arg_var, do: {pos, kind, var}

      assert {"0", "literal", ":alpha"} in args
      assert {"1", "literal", ~s("beta")} in args
      assert {"2", "literal", "7"} in args
      refute Enum.any?(args, &match?({"3", _, _}, &1))
    end

    test "what a function returns, on every path, but not a boolean", %{raw: raw, m: m} do
      assert [m <> ":name/0", "literal", ":cache"] in raw.return_var
      assert [m <> ":either/1", "literal", ":left"] in raw.return_var
      assert [m <> ":either/1", "literal", ":right"] in raw.return_var
      flag = m <> ":flag/0"
      refute Enum.any?(raw.return_var, &match?([^flag | _], &1))
    end

    test "a field of a term emitted for its other sources", %{raw: raw, m: m} do
      stored = m <> ":stored/1"
      assert Enum.any?(raw.field_store, &match?([^stored, _, ":mode", "literal", ":fast"], &1))
    end

    test "a literal handed where value flow does not follow is no use", %{raw: raw, m: m} do
      logged = m <> ":logged/2"
      assert Enum.any?(raw.unmodeled_use, &match?([_, ^logged, "param", "1"], &1))
      refute Enum.any?(raw.unmodeled_use, &match?([_, ^logged, "literal", _], &1))
    end
  end

  describe "summaries" do
    test "a wrapper's result is a site; call_result_var names the callee" do
      f = facts([F.Owner])
      [site] = for [s, "Owner:run/0", "Worker:start_link/1"] <- f.call_result_var, do: s
      assert Enum.any?(f.field_load, &match?(["Owner:run/0", _, "{1}", "result", ^site], &1))

      assert ["Owner:hand_off/1", "Owner:relay/1", "0", "call", "param", "0"] in unsited(
               f.call_arg_var
             )
    end

    test "a server start's init argument reaches init/1" do
      assert ["Worker:start_link/1", "Worker:init/1", "0", "init", "param", "0"] in unsited(
               facts([F.Worker]).call_arg_var
             )

      assert ["CycleA:init/1", "CycleB:start_link/1", "0", "call", "self", "self"] in unsited(
               facts([F.CycleA]).call_arg_var
             )
    end

    test "a call's target survives being parked across another call" do
      f = facts([F.Owner])

      assert [
               "Owner:across_a_call/0",
               "call",
               "process",
               "server Owner:across_a_call/0#9"
             ] in unsited(f.process_call_var)
    end

    test "a call's target survives the trim that renumbers its slot" do
      calls = unsited(facts([F.Owner]).process_call_var)

      assert ["Owner:across_a_trim/0", "call", "process", "server Owner:across_a_trim/0#15"] in calls

      assert ["Owner:across_a_trim/0", "call", "process", "server Owner:across_a_trim/0#9"] in calls

      assert Enum.count(calls, &match?(["Owner:across_a_trim/0" | _], &1)) == 2
    end

    test "an API function's call and cast target its parameter" do
      f = facts([F.Worker])
      assert ["Worker:ping/1", "call", "param", "0"] in unsited(f.process_call_var)
      assert ["Worker:notify/1", "cast", "param", "0"] in unsited(f.process_call_var)
    end

    test "register stores a pid under a name; a send reads a name or a captured pid" do
      f = facts([F.Loops])

      assert ["Loops:start/0", ":loops", "process", "spawn Loops:start/0#10"] in unsited(
               f.process_register_var
             )

      assert Enum.any?(
               f.process_send_var,
               &match?([_, "Loops:start/0", ":tick", "name", ":loops"], &1)
             )

      assert Enum.any?(
               f.process_send_var,
               &match?([_, "Loops:-start/0-fun-0-/1", "{:done, …}", "param", "0"], &1)
             )

      assert [
               "Loops:start/0",
               "Loops:-start/0-fun-0-/1",
               "0",
               "closure",
               "process",
               "spawn Loops:start/0#10"
             ] in unsited(f.call_arg_var)
    end

    test "a supervisor's start_child starts the child spec's module" do
      f = facts([F.Owner])

      assert ["Owner:dynamic/0", "server Owner:dynamic/0#8", "server", "Worker"] in unsited(
               f.process_start
             )
    end

    test "a literal target is a name" do
      f = facts([F.Hub, F.Listener])
      assert ["Hub:subscribe/1", "cast", "name", "Hub"] in unsited(f.process_call_var)

      assert ["Listener:init/1", "Hub:subscribe/1", "0", "call", "self", "self"] in unsited(
               f.call_arg_var
             )
    end

    test "a send is also an info call" do
      f = facts([F.Loops])
      assert ["Loops:start/0", "info", "name", ":loops"] in unsited(f.process_call_var)
      assert ["Loops:-start/0-fun-0-/1", "info", "param", "0"] in unsited(f.process_call_var)
    end

    test "spawn/4 passes its argument list, after the node, to what it runs" do
      f = facts([F.Starts])

      assert ["Starts:remote/0", "Starts:relay/1", "0", "spawn", "self", "self"] in unsited(
               f.call_arg_var
             )
    end

    test "a start with a literal name registers its process; so do register_name and Registry" do
      f = facts([F.Names, F.Starts])
      registers = unsited(f.process_register_var)

      assert ["Names:start_link/1", "{:global, :names}", "process", "server Names:start_link/1#7"] in registers
      assert ["Names:init/1", "{:via, Registry, {Reg, :names}}", "self", "self"] in registers
      assert ["Starts:agent/0", ":counter", "process", "agent Starts:agent/0#8"] in registers
    end

    test "lookups name the registry the name lives in" do
      f = facts([F.Names])
      calls = unsited(f.process_call_var)

      assert ["Names:ping_global/0", "call", "name", "{:global, :names}"] in calls
      assert ["Names:ping_whereis/0", "call", "name", "{:global, :names}"] in calls
      assert ["Names:ping_registry/0", "call", "name", "{:via, Registry, {Reg, :names}}"] in calls
    end

    test "an exit signal, a monitor and a link name their target" do
      f = facts([F.Keeper])
      signals = unsited(f.process_signal_var)

      assert Enum.any?(signals, &match?(["Keeper:handle_cast/2", "exit", "load", _], &1))
      assert ["Keeper:stop/1", "exit", "param", "0"] in signals

      assert Enum.any?(
               signals,
               &match?(["Keeper:init/1", "monitor", "process", "spawn " <> _], &1)
             )
    end

    test "the compiler's generated functions emit nothing" do
      for {_relation, rows} <- facts([F.Worker, F.Loops]), row <- rows do
        refute Enum.any?(row, &String.contains?(&1, ["__info__", "module_info"])), inspect(row)
      end
    end
  end
end
