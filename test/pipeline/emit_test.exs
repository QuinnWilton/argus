defmodule Argus.Pipeline.EmitTest do
  @moduledoc """
  The relations only the emitter makes of an instruction: calls, spawns,
  literals, branches, receives, lines. What it records of every
  instruction's reads, writes, fall-through and targets is
  `Argus.Instr`'s, which `Argus.InstrTest` checks instruction by
  instruction and, for the emitter, over the functions of real modules.
  """
  use ExUnit.Case, async: true

  alias Argus.Pipeline.{Disassemble, Emit}

  # Helper to emit facts for a single function in a minimal module.
  defp emit_func(instructions, opts \\ []) do
    mod = Keyword.get(opts, :module, TestMod)
    name = Keyword.get(opts, :name, :test_func)
    arity = Keyword.get(opts, :arity, 0)
    entry = Keyword.get(opts, :entry, 1)
    exports = Keyword.get(opts, :exports, [{name, arity, entry}])
    line_table = Keyword.get(opts, :line_table, %{})

    Emit.emit_module(mod, exports, [{:function, name, arity, entry, instructions}], line_table)
  end

  describe "module-level facts" do
    test "emits function_def with exported flag" do
      facts = emit_func([{:label, 1}, :return])
      defs = facts[:function_def]
      assert length(defs) == 1
      [func_id, "TestMod", "test_func", "0", "1"] = hd(defs)
      assert func_id == "TestMod:test_func/0"
    end

    test "marks non-exported functions" do
      facts =
        Emit.emit_module(
          MyMod,
          [{:public_fn, 0, 1}],
          [
            {:function, :public_fn, 0, 1, [{:label, 1}, :return]},
            {:function, :private_fn, 0, 2, [{:label, 2}, :return]}
          ]
        )

      defs = facts[:function_def]
      public = Enum.find(defs, fn [_, _, name, _, _] -> name == "public_fn" end)
      private = Enum.find(defs, fn [_, _, name, _, _] -> name == "private_fn" end)

      assert List.last(public) == "1"
      assert List.last(private) == "0"
    end
  end

  describe "instruction facts" do
    test "emits instruction for each instruction" do
      facts = emit_func([{:label, 1}, {:move, {:atom, :ok}, {:x, 0}}, :return])
      instrs = facts[:instruction]
      assert length(instrs) == 3
    end
  end

  describe "label facts" do
    test "emits label_at" do
      facts = emit_func([{:label, 42}])
      assert [["42", _id]] = facts[:label_at]
    end
  end

  describe "move facts" do
    test "emits literal_value for constant moves" do
      facts = emit_func([{:move, {:integer, 42}, {:x, 0}}])
      assert [[_id, "x0", "42"]] = facts[:literal_value]
    end

    test "emits literal_value for atom moves" do
      facts = emit_func([{:move, {:atom, :ok}, {:x, 0}}])
      assert [[_id, "x0", ":ok"]] = facts[:literal_value]
    end

    test "spells an improper list literal instead of crashing on it" do
      # Logger.Translator carries [prefix | "    "]; mapping it as a proper
      # list raised and took the whole module's extraction with it.
      facts = emit_func([{:move, {:literal, [:a | "  "]}, {:x, 0}}])
      assert [[_id, "x0", ~s([:a | "  "])]] = facts[:literal_value]
    end

    test "drops location metadata from literals" do
      # Logger's metadata keyword carries the call site; a line shift
      # must not change a semantic fact.
      meta = [file: "lib/a.ex", line: 3, mfa: {A, :b, 1}]
      facts = emit_func([{:move, {:literal, meta}, {:x, 0}}])
      assert [[_id, "x0", "[mfa: {A, :b, 1}]"]] = facts[:literal_value]

      # Nested inside a larger literal too.
      facts = emit_func([{:move, {:literal, {:log, %{file: "a", line: 9, module: A}}}, {:x, 0}}])
      assert [[_id, "x0", "{:log, %{module: A}}"]] = facts[:literal_value]

      # A bare line: keyword is a program's own data, not a location.
      facts = emit_func([{:move, {:literal, [line: 3]}, {:x, 0}}])
      assert [[_id, "x0", "[line: 3]"]] = facts[:literal_value]
    end
  end

  describe "call facts" do
    test "emits remote_call for call_ext" do
      facts = emit_func([{:call_ext, 2, {:extfunc, :erlang, :+, 2}}])
      assert [[_id, _caller, ":erlang", "+", "2"]] = facts[:remote_call]
    end

    test "emits tail_call for call_ext_only" do
      facts = emit_func([{:call_ext_only, 1, {:extfunc, :lists, :reverse, 1}}])
      assert [[_id]] = facts[:tail_call]
      assert [[_id, _caller, ":lists", "reverse", "1"]] = facts[:remote_call]
    end

    test "emits local_call for modern MFA-style calls" do
      facts = emit_func([{:call, 2, {MyMod, :helper, 2}}])
      assert [[_id, _caller, "MyMod:helper/2", "2"]] = facts[:local_call]
    end

    test "emits tail_call for call_only" do
      facts = emit_func([{:call_only, 2, {MyMod, :helper, 2}}])
      assert [[_id]] = facts[:tail_call]
    end

    test "emits bif_call for bif" do
      facts = emit_func([{:bif, :element, {:f, 0}, [{:integer, 2}, {:x, 0}], {:x, 0}}])
      assert [[_id, _caller, ":erlang", "element", "2", "0"]] = facts[:bif_call]
    end

    test "emits bif_call for gc_bif" do
      facts = emit_func([{:gc_bif, :+, {:f, 0}, 1, [{:x, 0}, {:integer, 1}], {:x, 0}}])
      assert [[_id, _caller, ":erlang", "+", "2", "0"]] = facts[:bif_call]
    end

    # [mod, func, arity, variant, api, source, param, args] of the one row.
    defp spawned(facts) do
      assert [[_id, _caller | row]] = facts[:spawn_call]
      row
    end

    test "emits spawn_call for erlang:spawn/3" do
      facts = emit_func([{:call_ext, 3, {:extfunc, :erlang, :spawn, 3}}])

      assert spawned(facts) ==
               ["dynamic", "dynamic", "-1", "spawn", ":erlang.spawn/3", "dynamic", "-1", "2"]
    end

    test "emits spawn_call for erlang:spawn_link/3" do
      facts = emit_func([{:call_ext, 3, {:extfunc, :erlang, :spawn_link, 3}}])
      assert ["dynamic", "dynamic", "-1", "spawn_link" | _] = spawned(facts)
    end

    test "emits spawn_call for erlang:spawn_monitor/1" do
      facts = emit_func([{:call_ext, 1, {:extfunc, :erlang, :spawn_monitor, 1}}])

      assert spawned(facts) ==
               [
                 "dynamic",
                 "dynamic",
                 "-1",
                 "spawn_monitor",
                 ":erlang.spawn_monitor/1",
                 "dynamic",
                 "-1",
                 "-1"
               ]
    end

    test "spawn_call names what spawn/3 runs from its literal arguments" do
      facts =
        emit_func([
          {:move, {:atom, Cart}, {:x, 0}},
          {:move, {:atom, :loop}, {:x, 1}},
          {:put_list, {:integer, 1}, nil, {:x, 2}},
          {:call_ext, 3, {:extfunc, :erlang, :spawn, 3}}
        ])

      assert ["Cart", "loop", "1", "spawn", ":erlang.spawn/3", "mfa", "-1", "2"] = spawned(facts)
    end

    test "spawn_call names what the node-qualified spawn/4 runs" do
      facts =
        emit_func([
          {:move, {:atom, Cart}, {:x, 1}},
          {:move, {:atom, :loop}, {:x, 2}},
          {:move, nil, {:x, 3}},
          {:call_ext, 4, {:extfunc, :erlang, :spawn, 4}}
        ])

      assert ["Cart", "loop", "0", "spawn", ":erlang.spawn/4", "mfa", "-1", "3"] = spawned(facts)
    end

    test "spawn_call names the function a spawned closure was lifted to" do
      facts =
        emit_func([
          {:make_fun3, {Shop, :"-start/1-fun-0-", 1}, 0, 0, {:x, 0}, {:list, [{:x, 0}]}},
          {:call_ext, 1, {:extfunc, :erlang, :spawn_link, 1}}
        ])

      assert ["Shop", "-start/1-fun-0-", "1", "spawn_link", _, "closure", "-1", "-1"] =
               spawned(facts)
    end

    test "spawn_call names the function a literal external fun names" do
      facts =
        emit_func([
          {:move, {:literal, &URI.parse/1}, {:x, 0}},
          {:call_ext_only, 1, {:extfunc, :erlang, :spawn, 1}}
        ])

      assert ["URI", "parse", "1", "spawn", _, "fun", "-1", "-1"] = spawned(facts)
    end

    test "a spawned fun the caller was handed is its parameter" do
      facts =
        emit_func(
          [
            {:label, 1},
            {:func_info, {:atom, TestMod}, {:atom, :test_func}, 2},
            {:label, 2},
            {:move, {:x, 1}, {:x, 0}},
            {:call_ext_only, 1, {:extfunc, :erlang, :spawn, 1}}
          ],
          arity: 2
        )

      assert ["dynamic", "dynamic", "-1", "spawn", _, "param", "1", "-1"] = spawned(facts)
    end

    test "an argument list with an unknown tail keeps the module and function" do
      facts =
        emit_func([
          {:move, {:atom, Cart}, {:x, 0}},
          {:move, {:atom, :loop}, {:x, 1}},
          {:put_list, {:integer, 1}, {:y, 0}, {:x, 2}},
          {:call_ext, 3, {:extfunc, :erlang, :spawn, 3}}
        ])

      assert ["Cart", "loop", "-1", "spawn", _, "mfa", "-1", "2"] = spawned(facts)
    end

    test "an unknown module keeps the literal function beside it" do
      facts =
        emit_func(
          [
            {:move, {:atom, :loop}, {:x, 1}},
            {:move, nil, {:x, 2}},
            {:call_ext, 3, {:extfunc, :erlang, :spawn, 3}}
          ],
          arity: 1
        )

      assert ["dynamic", "loop", "-1", "spawn", _, "dynamic", "-1", "2"] = spawned(facts)
    end

    test "emits spawn_call for erlang:spawn/1" do
      facts = emit_func([{:call_ext, 1, {:extfunc, :erlang, :spawn, 1}}])
      assert ["dynamic", "dynamic", "-1", "spawn" | _] = spawned(facts)
    end

    test "spawn_opt's literal options say how the process is tied" do
      for {opts, variant} <- [
            {[:link], "spawn_link"},
            {[:monitor], "spawn_monitor"},
            {[{:monitor, [tag: :t]}], "spawn_monitor"},
            {[:link, :monitor], "spawn_link"},
            {[{:priority, :high}], "spawn"}
          ] do
        facts =
          emit_func([
            {:make_fun3, {Shop, :"-go/0-fun-0-", 0}, 0, 0, {:x, 0}, {:list, []}},
            {:move, {:literal, opts}, {:x, 1}},
            {:call_ext_only, 2, {:extfunc, :erlang, :spawn_opt, 2}}
          ])

        assert ["Shop", "-go/0-fun-0-", "0", ^variant, ":erlang.spawn_opt/2", "closure" | _] =
                 spawned(facts)
      end

      facts =
        emit_func(
          [
            {:label, 1},
            {:func_info, {:atom, TestMod}, {:atom, :test_func}, 2},
            {:label, 2},
            {:call_ext_only, 2, {:extfunc, :erlang, :spawn_opt, 2}}
          ],
          arity: 2
        )

      assert ["dynamic", "dynamic", "-1", "spawn_opt", _, "param", "0", "-1"] = spawned(facts)
    end

    test "proc_lib's spawns and starts are spawns" do
      mfa = [
        {:move, {:atom, Cart}, {:x, 0}},
        {:move, {:atom, :init_it}, {:x, 1}},
        {:move, nil, {:x, 2}}
      ]

      for {fun, arity, variant} <- [
            {:start_link, 3, "spawn_link"},
            {:start, 4, "start"},
            {:start_monitor, 3, "spawn_monitor"},
            {:spawn_link, 3, "spawn_link"},
            {:spawn, 3, "spawn"}
          ] do
        facts = emit_func(mfa ++ [{:call_ext, arity, {:extfunc, :proc_lib, fun, arity}}])
        api = ":proc_lib.#{fun}/#{arity}"

        assert ["Cart", "init_it", "0", ^variant, ^api, "mfa", "-1", "2"] = spawned(facts)
      end
    end

    test "proc_lib:start/5 is a start unless its spawn options tie it closer" do
      mfa = [
        {:move, {:atom, Cart}, {:x, 0}},
        {:move, {:atom, :init_it}, {:x, 1}},
        {:move, nil, {:x, 2}},
        {:move, {:atom, :infinity}, {:x, 3}}
      ]

      for {opts, variant} <- [
            {[], "start"},
            {[:link], "spawn_link"},
            {[:monitor], "spawn_monitor"}
          ] do
        facts =
          emit_func(
            mfa ++
              [
                {:move, {:literal, opts}, {:x, 4}},
                {:call_ext, 5, {:extfunc, :proc_lib, :start, 5}}
              ]
          )

        assert ["Cart", "init_it", "0", ^variant | _] = spawned(facts)
      end
    end
  end

  describe "resolved_apply" do
    test "the apply instruction's module and function registers name its target" do
      facts =
        emit_func([
          {:move, {:atom, URI}, {:x, 1}},
          {:move, {:atom, :parse}, {:x, 2}},
          {:apply, 1},
          :return
        ])

      assert [[_id, "TestMod:test_func/0", "URI:parse/1"]] = facts[:resolved_apply]
      assert [[_id, "TestMod:test_func/0", "apply"]] = facts[:dynamic_call]
    end

    test "an apply_last whose module is unknown resolves nothing" do
      facts = emit_func([{:move, {:atom, :parse}, {:x, 2}}, {:apply_last, 1, 0}])
      assert facts[:resolved_apply] == nil
    end

    test "erlang:apply/3 needs the argument list's length" do
      known =
        emit_func([
          {:move, {:atom, URI}, {:x, 0}},
          {:move, {:atom, :merge}, {:x, 1}},
          {:put_list, {:x, 3}, {:literal, [:b]}, {:x, 2}},
          {:call_ext, 3, {:extfunc, :erlang, :apply, 3}},
          :return
        ])

      assert [[_id, _caller, "URI:merge/2"]] = known[:resolved_apply]

      open =
        emit_func([
          {:move, {:atom, URI}, {:x, 0}},
          {:move, {:atom, :merge}, {:x, 1}},
          {:put_list, {:x, 3}, {:x, 4}, {:x, 2}},
          {:call_ext, 3, {:extfunc, :erlang, :apply, 3}},
          :return
        ])

      assert open[:resolved_apply] == nil
    end
  end

  describe "fun_ref" do
    test "a literal fun handed to a call is a reference" do
      facts =
        emit_func([
          {:move, {:literal, &URI.parse/1}, {:x, 1}},
          {:call_ext, 2, {:extfunc, Enum, :map, 2}},
          :return
        ])

      assert facts[:fun_ref] == [["TestMod:test_func/0", "URI:parse/1"]]
    end

    test "a fun the call hands back, or one built into data, is not" do
      facts =
        emit_func([
          # Keyword.get(opts, :on_fail, &URI.decode/1): the default comes back.
          {:move, {:atom, :on_fail}, {:x, 1}},
          {:move, {:literal, &URI.decode/1}, {:x, 2}},
          {:call_ext, 3, {:extfunc, Keyword, :get, 3}},
          # A table of funs held in a literal, and a fun put in a tuple.
          {:move, {:literal, %{parse: &URI.parse/1}}, {:x, 0}},
          {:put_tuple2, {:x, 0}, {:list, [{:literal, &String.upcase/1}, {:x, 1}]}},
          :return
        ])

      assert facts[:fun_ref] == nil
    end

    test "make_fun/3 of literals handed to a call is a reference" do
      literal =
        emit_func([
          {:move, {:atom, URI}, {:x, 0}},
          {:move, {:atom, :parse}, {:x, 1}},
          {:move, {:integer, 1}, {:x, 2}},
          {:call_ext, 3, {:extfunc, :erlang, :make_fun, 3}},
          {:move, {:x, 0}, {:x, 1}},
          {:move, {:y, 0}, {:x, 0}},
          {:call_ext, 2, {:extfunc, Enum, :each, 2}},
          :return
        ])

      assert literal[:fun_ref] == [["TestMod:test_func/0", "URI:parse/1"]]

      unknown =
        emit_func([
          {:move, {:atom, :parse}, {:x, 1}},
          {:move, {:integer, 1}, {:x, 2}},
          {:call_ext, 3, {:extfunc, :erlang, :make_fun, 3}},
          {:move, {:x, 0}, {:x, 1}},
          {:call_ext, 2, {:extfunc, Enum, :each, 2}},
          :return
        ])

      assert unknown[:fun_ref] == nil
    end

    test "a function that calls its reference's target has no row" do
      facts =
        emit_func([
          {:call_ext, 1, {:extfunc, URI, :parse, 1}},
          {:move, {:literal, &URI.parse/1}, {:x, 1}},
          {:call_ext, 2, {:extfunc, Enum, :map, 2}},
          :return
        ])

      assert facts[:fun_ref] == nil
    end
  end

  describe "fun_handed" do
    test "names the call a closure or a literal fun is handed to" do
      facts =
        emit_func([
          # Enum.each(peers, fn p -> ... end): the closure runs inside Enum.each.
          {:make_fun3, {TestMod, :"-test_func/0-fun-0-", 1}, 0, 0, {:x, 1}, {:list, []}},
          {:call_ext, 2, {:extfunc, Enum, :each, 2}},
          {:move, {:literal, &URI.parse/1}, {:x, 1}},
          {:call_ext, 2, {:extfunc, Enum, :map, 2}},
          :return
        ])

      # Each in the position it is handed in: the second argument.
      assert [
               [each_id, "TestMod:test_func/0", "TestMod:-test_func/0-fun-0-/1", "1"],
               [map_id, "TestMod:test_func/0", "URI:parse/1", "1"]
             ] = Enum.sort_by(facts[:fun_handed], &Enum.at(&1, 2))

      assert {:ok, %{idx: 1}} = Argus.InstrId.parse(each_id)
      assert {:ok, %{idx: 3}} = Argus.InstrId.parse(map_id)
    end

    test "a fun the call hands back is not handed to it" do
      facts =
        emit_func([
          {:move, {:atom, :on_fail}, {:x, 1}},
          {:move, {:literal, &URI.decode/1}, {:x, 2}},
          {:call_ext, 3, {:extfunc, Keyword, :get, 3}},
          :return
        ])

      assert facts[:fun_handed] == nil
    end
  end

  describe "control flow facts" do
    test "emits jump" do
      facts = emit_func([{:jump, {:f, 5}}])
      assert [[_id, "5"]] = facts[:jump]
    end

    test "emits branch for test" do
      facts = emit_func([{:test, :is_atom, {:f, 3}, [{:x, 0}]}])
      assert [[_id, "3", "0"]] = facts[:branch]
    end

    test "emits select_branch for select_val" do
      facts =
        emit_func([
          {:select_val, {:x, 0}, {:f, 10},
           {:list, [{:atom, :a}, {:f, 11}, {:atom, :b}, {:f, 12}]}}
        ])

      branches = facts[:select_branch]
      # fail + 2 cases
      assert length(branches) == 3
    end
  end

  describe "stack bookkeeping" do
    # No rule read allocate, deallocate, try_end or move rows; the
    # in-process passes read the instructions themselves.
    test "has no relation of its own" do
      facts =
        emit_func([
          {:allocate, 3, 2},
          {:allocate_heap, 3, 5, 2},
          {:deallocate, 3},
          {:try_end, {:y, 0}}
        ])

      for relation <- [:allocate, :deallocate, :try_end, :move] do
        refute Map.has_key?(facts, relation)
      end
    end
  end

  describe "message facts" do
    test "emits send_msg" do
      facts = emit_func([:send])
      assert [[_id, _caller]] = facts[:send_msg]
    end

    test "emits recv_start for loop_rec" do
      facts = emit_func([{:loop_rec, {:f, 5}, {:x, 0}}])
      assert [[_id, _caller, _blocking, "5"]] = facts[:recv_start]
    end

    # Phoenix's Channel.Server.close/2: a grace period for the :DOWN, then
    # a kill and a wait without one. The first receive's empty-mailbox
    # block ends in wait_timeout; the second's wait comes after it.
    test "a timed receive before a blocking one is timed" do
      facts =
        emit_func([
          {:label, 1},
          {:loop_rec, {:f, 2}, {:x, 0}},
          :remove_message,
          {:label, 2},
          {:wait_timeout, {:f, 1}, {:integer, 100}},
          :timeout,
          {:label, 3},
          {:loop_rec, {:f, 4}, {:x, 0}},
          :remove_message,
          {:label, 4},
          {:wait, {:f, 3}}
        ])

      assert [["TestMod:test_func/0#1", _, "0", "2"], ["TestMod:test_func/0#7", _, "1", "4"]] =
               Enum.sort(facts[:recv_start])
    end

    # io's execute_request/3: after the :DOWN, a look for the :EXIT with
    # `after 0`, whose empty-mailbox block has no wait at all, inside a
    # function whose other receive waits further down.
    test "an after-0 receive before a blocking one is not blocking" do
      facts =
        emit_func([
          {:label, 1},
          {:loop_rec, {:f, 2}, {:x, 0}},
          :remove_message,
          {:label, 2},
          :timeout,
          {:label, 3},
          {:loop_rec, {:f, 4}, {:x, 0}},
          :remove_message,
          {:label, 4},
          {:wait, {:f, 3}}
        ])

      assert [["TestMod:test_func/0#1", _, "0", "2"], ["TestMod:test_func/0#6", _, "1", "4"]] =
               Enum.sort(facts[:recv_start])
    end
  end

  describe "exception facts" do
    test "emits try_start" do
      facts = emit_func([{:try, {:y, 0}, {:f, 10}}])
      assert [[_id, _caller, "try", "10"]] = facts[:try_start]
    end
  end

  describe "closure_def facts" do
    test "emits closure_def edge from parent func to closure body for MFA target" do
      facts =
        emit_func(
          [{:make_fun3, {TestMod, :"-test_func/0-fun-0-", 1}, 0, 0, {:x, 0}, {:list, []}}],
          name: :test_func,
          arity: 0
        )

      assert [[parent, closure]] = facts[:closure_def]
      assert parent == "TestMod:test_func/0"
      assert closure == "TestMod:-test_func/0-fun-0-/1"
    end

    test "does not emit closure_def for label-targeted make_fun3" do
      facts = emit_func([{:make_fun3, {:f, 15}, 0, 0, {:x, 0}, {:list, []}}])
      assert facts[:closure_def] == nil
    end
  end

  describe "type_test facts" do
    test "emits type_test for is_atom against the source register" do
      facts = emit_func([{:test, :is_atom, {:f, 3}, [{:x, 0}]}])
      assert [[_id, "is_atom", "x0", "3"]] = facts[:type_test]
    end

    test "emits type_test for is_integer in the live-count form" do
      facts = emit_func([{:test, :is_integer, {:f, 4}, 1, [{:x, 1}]}])
      assert [[_id, "is_integer", "x1", "4"]] = facts[:type_test]
    end

    test "does not emit type_test for non-type tests like is_eq_exact" do
      facts = emit_func([{:test, :is_eq_exact, {:f, 5}, [{:x, 0}, {:atom, :ok}]}])
      assert facts[:type_test] == nil
    end

    test "emits type_test for the structural is_nonempty_list" do
      facts = emit_func([{:test, :is_nonempty_list, {:f, 7}, [{:x, 0}]}])
      assert [[_id, "is_nonempty_list", "x0", "7"]] = facts[:type_test]
    end

    test "emits type_test for is_tagged_tuple with src as the tested register" do
      facts = emit_func([{:test, :is_tagged_tuple, {:f, 8}, [{:x, 0}, 2, {:atom, :ok}]}])
      assert [[_id, "is_tagged_tuple", "x0", "8"]] = facts[:type_test]
    end

    test "still emits the generic branch fact alongside type_test" do
      facts = emit_func([{:test, :is_tuple, {:f, 6}, [{:x, 0}]}])
      assert [[_id, "6", "0"]] = facts[:branch]
      assert [[_id2, "is_tuple", "x0", "6"]] = facts[:type_test]
    end
  end

  describe "line_info facts" do
    test "resolves the Line-chunk reference to a real source line" do
      facts = emit_func([{:line, 2}], line_table: %{1 => 10, 2 => 42})
      assert [[_id, "42"]] = facts[:line_info]
    end

    test "emits nothing for reference 0 (no location)" do
      facts = emit_func([{:line, 0}], line_table: %{1 => 10})
      assert facts[:line_info] == nil
    end

    test "emits nothing without a line table (no Line chunk)" do
      facts = emit_func([{:line, 42}])
      assert facts[:line_info] == nil
    end

    test "still records the marker in the instruction relation" do
      facts = emit_func([{:line, 0}], line_table: %{})
      assert Enum.any?(facts[:instruction], fn [_id, _func, _idx, op] -> op == "line" end)
    end

    test "stamps the line in effect onto every following instruction" do
      facts =
        emit_func(
          [
            {:line, 1},
            {:move, {:atom, :ok}, {:x, 0}},
            {:line, 2},
            {:call_ext, 1, {:extfunc, :erlang, :whereis, 1}}
          ],
          line_table: %{1 => 10, 2 => 20}
        )

      assert [
               ["TestMod:test_func/0#0", "10"],
               ["TestMod:test_func/0#1", "10"],
               ["TestMod:test_func/0#2", "20"],
               ["TestMod:test_func/0#3", "20"]
             ] = Enum.sort(facts[:line_info])
    end

    test "a no-location marker resets the line in effect" do
      facts =
        emit_func(
          [
            {:line, 1},
            {:move, {:atom, :ok}, {:x, 0}},
            {:line, 0},
            {:call_ext, 1, {:extfunc, :erlang, :whereis, 1}}
          ],
          line_table: %{1 => 10}
        )

      # Compiler-generated code after the reset must not inherit line 10.
      assert [
               ["TestMod:test_func/0#0", "10"],
               ["TestMod:test_func/0#1", "10"]
             ] = Enum.sort(facts[:line_info])
    end

    # OTP 29's beam_disasm resolves a `line` marker to its location (a
    # `debug_line` still carries the reference); OTP 28's leaves the
    # reference, which the table resolves. Both give the same rows.
    test "a marker OTP 29 resolved to its location stamps that line, with no table" do
      facts =
        emit_func([
          {:line, [{:location, ~c"lib/a.ex", 10}]},
          {:move, {:atom, :ok}, {:x, 0}},
          {:line, [{:location, ~c"lib/a.ex", 20}]},
          {:call_ext, 1, {:extfunc, :erlang, :whereis, 1}}
        ])

      referenced =
        emit_func(
          [
            {:line, 1},
            {:move, {:atom, :ok}, {:x, 0}},
            {:line, 2},
            {:call_ext, 1, {:extfunc, :erlang, :whereis, 1}}
          ],
          line_table: %{1 => 10, 2 => 20}
        )

      assert [
               ["TestMod:test_func/0#0", "10"],
               ["TestMod:test_func/0#1", "10"],
               ["TestMod:test_func/0#2", "20"],
               ["TestMod:test_func/0#3", "20"]
             ] = Enum.sort(facts[:line_info])

      assert facts == referenced
    end

    test "an OTP 29 marker with no location resets the line in effect" do
      facts =
        emit_func([
          {:line, [{:location, ~c"lib/a.ex", 10}]},
          {:move, {:atom, :ok}, {:x, 0}},
          {:line, []},
          {:call_ext, 1, {:extfunc, :erlang, :whereis, 1}}
        ])

      assert [
               ["TestMod:test_func/0#0", "10"],
               ["TestMod:test_func/0#1", "10"]
             ] = Enum.sort(facts[:line_info])
    end

    test "a try takes the line of the marker after it, in either form" do
      for marker <- [3, [{:location, ~c"lib/a.ex", 30}]] do
        facts =
          emit_func(
            [
              {:line, 1},
              {:label, 2},
              {:try, {:y, 0}, {:f, 9}},
              {:line, marker},
              {:call_ext, 1, {:extfunc, :erlang, :whereis, 1}}
            ],
            line_table: %{1 => 10, 3 => 30}
          )

        assert ["TestMod:test_func/0#2", "30"] in facts[:line_info], inspect(marker)
      end
    end

    test "Disassemble.marker_line/2 reads a reference through the table, and a location as it is" do
      table = %{1 => 10}
      assert Disassemble.marker_line(1, table) == 10
      assert Disassemble.marker_line(0, table) == nil
      assert Disassemble.marker_line(7, table) == nil
      assert Disassemble.marker_line([{:location, ~c"lib/a.ex", 12}], table) == 12
      assert Disassemble.marker_line([], table) == nil
    end

    test "instructions before the first marker carry no line" do
      facts =
        emit_func(
          [
            {:label, 1},
            {:move, {:atom, :ok}, {:x, 0}},
            {:line, 1},
            :return
          ],
          line_table: %{1 => 10}
        )

      assert [
               ["TestMod:test_func/0#2", "10"],
               ["TestMod:test_func/0#3", "10"]
             ] = Enum.sort(facts[:line_info])
    end
  end

  describe "bs_start_match4 facts" do
    test "emits bs_start with its fail label" do
      facts = emit_func([{:bs_start_match4, {:f, 5}, 1, {:x, 0}, {:x, 1}}])
      assert [[_, "5"]] = facts[:bs_start]
    end
  end

  describe "literal operands" do
    alias Argus.Test.Fixtures.LoudInspect, as: Loud

    test "a struct literal is spelled without its Inspect implementation" do
      # The implementation is live: defined in a test module it would
      # come after protocol consolidation and do nothing, and this test
      # would pass without exercising it.
      assert inspect(%Loud{}) =~ "Inspect.Error"

      facts = emit_func([{:move, {:literal, %Loud{}}, {:x, 0}}, :return])
      assert [[_, "x0", spelled]] = facts[:literal_value]
      refute String.contains?(spelled, ["\n", "\t", "#Loud<", "Inspect.Error"])
      assert spelled == "%{__struct__: #{inspect(Loud)}, items: nil}"
    end

    # inspect/2 stops at 50 elements and at 4096 bytes of a string, so these
    # pairs used to spell the same and join as one value.
    test "literals that differ past inspect's bounds spell differently" do
      pairs = [
        {Enum.to_list(1..60), Enum.to_list(1..59) ++ [:other]},
        {String.duplicate("a", 5000), String.duplicate("a", 4999) <> "b"},
        {Map.new(1..60, &{&1, &1}), Map.new(1..60, &{&1, -&1})},
        {List.to_tuple(Enum.to_list(1..60)), List.to_tuple(Enum.to_list(1..59) ++ [0])}
      ]

      for {a, b} <- pairs do
        refute spelling(a) == spelling(b)
        assert spelling(a) == spelling(a)
      end
    end

    test "a literal inspect spells in full keeps its plain spelling" do
      for value <- [[1, 2, 3], %{a: [b: "c"]}, {:ok, "x"}, Enum.to_list(1..50)] do
        assert spelling(value) == inspect(value, structs: false)
      end
    end

    defp spelling(value) do
      facts = emit_func([{:move, {:literal, value}, {:x, 0}}, :return])
      [[_, "x0", spelled]] = facts[:literal_value]
      spelled
    end
  end

  describe "caller columns" do
    # The point of the caller column is that a rule can get a call's
    # containing function without joining `instruction`. That is only true
    # if the column actually holds it, and the pattern-shape assertions
    # above would pass just as happily with a constant in that slot.
    @caller_bearing [:remote_call, :local_call, :bif_call, :spawn_call, :try_start]

    test "every call fact's caller is the function its instruction belongs to" do
      {:ok, facts} = Argus.Pipeline.extract([:lists, :maps, :gen_server])

      checked =
        for relation <- @caller_bearing,
            row <- Map.get(facts, relation, []) do
          [id, caller | _] = row

          assert {:ok, ^caller} = Argus.InstrId.func_id_of(id),
                 "#{relation}: caller #{inspect(caller)} is not the function containing #{id}"

          relation
        end

      # Guard against the fixture silently emitting nothing at all.
      assert length(checked) > 100
      assert Enum.uniq(checked) |> length() >= 3
    end

    test "try_start records which syntax produced it" do
      {:ok, facts} = Argus.Pipeline.extract([:gen_server])
      kinds = facts |> Map.get(:try_start, []) |> Enum.map(&Enum.at(&1, 2)) |> Enum.uniq()

      refute kinds == []
      assert Enum.all?(kinds, &(&1 in ["try", "catch"])), "unexpected try kind: #{inspect(kinds)}"
    end
  end
end
