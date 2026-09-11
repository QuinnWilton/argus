defmodule Argus.Pipeline.EmitTest do
  use ExUnit.Case, async: true

  alias Argus.Pipeline.Emit

  # Helper to emit facts for a single function in a minimal module.
  defp emit_func(instructions, opts \\ []) do
    mod = Keyword.get(opts, :module, TestMod)
    name = Keyword.get(opts, :name, :test_func)
    arity = Keyword.get(opts, :arity, 0)
    entry = Keyword.get(opts, :entry, 1)
    exports = Keyword.get(opts, :exports, [{name, arity, entry}])
    line_table = Keyword.get(opts, :line_table, %{})

    Emit.emit_module(
      mod,
      exports,
      [],
      [],
      [{:function, name, arity, entry, instructions}],
      line_table
    )
  end

  describe "module-level facts" do
    test "emits module_info" do
      facts = Emit.emit_module(MyMod, [], [], [], [])
      assert [["MyMod", "MyMod"]] = facts[:module_info]
    end

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
          [],
          [],
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

    test "emits import_ref" do
      facts = Emit.emit_module(MyMod, [], [{:erlang, :+, 2}], [], [])
      assert [[":erlang", "+", "2"]] = facts[:import_ref]
    end

    test "emits module_attribute" do
      facts = Emit.emit_module(MyMod, [], [], [behaviour: [GenServer]], [])
      assert [[_, "behaviour", "GenServer"]] = facts[:module_attribute]
    end
  end

  describe "instruction facts" do
    test "emits instruction for each instruction" do
      facts = emit_func([{:label, 1}, {:move, {:atom, :ok}, {:x, 0}}, :return])
      instrs = facts[:instruction]
      assert length(instrs) == 3
    end

    test "emits next for sequential instructions" do
      facts = emit_func([{:label, 1}, {:move, {:atom, :ok}, {:x, 0}}, :return])
      nexts = facts[:next]
      # label -> move, but not move -> return (return is not a terminator,
      # but the next is emitted). Actually return IS not followed by next since
      # there's nothing after it. Let's check:
      # label -> move (yes), move -> return (move is not a terminator, so yes)
      assert length(nexts) == 2
    end

    test "does not emit next after terminators" do
      facts = emit_func([{:label, 1}, {:jump, {:f, 1}}, {:label, 2}, :return])
      nexts = facts[:next]
      # label -> jump (yes), jump -> label (NO, jump is terminator), label -> return (yes)
      assert length(nexts) == 2
    end
  end

  describe "label facts" do
    test "emits label_at" do
      facts = emit_func([{:label, 42}])
      assert [["42", _id]] = facts[:label_at]
    end
  end

  describe "move facts" do
    test "emits move, def, use for move instruction" do
      facts = emit_func([{:move, {:x, 0}, {:y, 1}}])
      assert [[_id, "x0", "y1"]] = facts[:move]
      assert Enum.any?(facts[:def], fn [_, reg] -> reg == "y1" end)
      assert Enum.any?(facts[:use], fn [_, reg] -> reg == "x0" end)
    end

    test "emits literal_value for constant moves" do
      facts = emit_func([{:move, {:integer, 42}, {:x, 0}}])
      assert [[_id, "x0", "42"]] = facts[:literal_value]
    end

    test "emits literal_value for atom moves" do
      facts = emit_func([{:move, {:atom, :ok}, {:x, 0}}])
      assert [[_id, "x0", ":ok"]] = facts[:literal_value]
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

    test "emits spawn_call for erlang:spawn/3" do
      facts = emit_func([{:call_ext, 3, {:extfunc, :erlang, :spawn, 3}}])
      assert [[_id, _caller, "dynamic", "dynamic", "3", "spawn"]] = facts[:spawn_call]
    end

    test "emits spawn_call for erlang:spawn_link/3" do
      facts = emit_func([{:call_ext, 3, {:extfunc, :erlang, :spawn_link, 3}}])
      assert [[_id, _caller, "dynamic", "dynamic", "3", "spawn_link"]] = facts[:spawn_call]
    end

    test "emits spawn_call for erlang:spawn_monitor/1" do
      facts = emit_func([{:call_ext, 1, {:extfunc, :erlang, :spawn_monitor, 1}}])
      assert [[_id, _caller, "dynamic", "dynamic", "1", "spawn_monitor"]] = facts[:spawn_call]
    end

    test "emits spawn_call for erlang:spawn/1" do
      facts = emit_func([{:call_ext, 1, {:extfunc, :erlang, :spawn, 1}}])
      assert [[_id, _caller, "dynamic", "dynamic", "1", "spawn"]] = facts[:spawn_call]
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

  describe "stack facts" do
    test "emits allocate" do
      facts = emit_func([{:allocate, 3, 2}])
      assert [[_id, "3", "2"]] = facts[:allocate]
    end

    test "emits allocate for allocate_heap (canonicalized)" do
      facts = emit_func([{:allocate_heap, 3, 5, 2}])
      assert [[_id, "3", "2"]] = facts[:allocate]
    end

    test "emits deallocate" do
      facts = emit_func([{:deallocate, 3}])
      assert [[_id, "3"]] = facts[:deallocate]
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

    test "emits recv_end for remove_message" do
      facts = emit_func([:remove_message])
      assert [[_id]] = facts[:recv_end]
    end
  end

  describe "exception facts" do
    test "emits try_start" do
      facts = emit_func([{:try, {:y, 0}, {:f, 10}}])
      assert [[_id, _caller, "try", "10"]] = facts[:try_start]
    end

    test "emits try_end" do
      facts = emit_func([{:try_end, {:y, 0}}])
      assert [[_id]] = facts[:try_end]
    end
  end

  describe "make_fun facts" do
    test "emits make_fun for make_fun3 with label" do
      facts = emit_func([{:make_fun3, {:f, 15}, 0, 123, {:x, 0}, {:list, [{:x, 1}]}}])
      assert [[_id, _caller, "15", "1"]] = facts[:make_fun]
    end

    test "emits make_fun for make_fun3 with MFA" do
      facts =
        emit_func([{:make_fun3, {MyMod, :"-fun/1-", 2}, 0, 123, {:x, 0}, {:list, [{:x, 1}]}}])

      fun_facts = facts[:make_fun]
      assert [[_id, _caller, target, "1"]] = fun_facts
      assert target == "MyMod:-fun/1-/2"
    end

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

  describe "tuple_field_access facts" do
    test "records the index of get_tuple_element" do
      facts = emit_func([{:get_tuple_element, {:x, 0}, 1, {:x, 2}}])
      assert [[_id, "x0", "1", "x2"]] = facts[:tuple_field_access]
    end

    test "still emits use and def for the source and destination" do
      facts = emit_func([{:get_tuple_element, {:x, 0}, 1, {:x, 2}}])
      assert Enum.any?(facts[:use], fn [_, reg] -> reg == "x0" end)
      assert Enum.any?(facts[:def], fn [_, reg] -> reg == "x2" end)
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

  describe "unhandled_op facts" do
    test "records opcodes that fall through to the catch-all" do
      # Use an instruction shape that no clause matches.
      facts = emit_func([{:totally_made_up_opcode, :foo, :bar}])
      assert [[_id, "totally_made_up_opcode"]] = facts[:unhandled_op]
    end

    test "does not emit unhandled_op for known opcodes" do
      facts = emit_func([{:move, {:atom, :ok}, {:x, 0}}])
      assert facts[:unhandled_op] == nil
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

  describe "swap facts" do
    test "emits def and use for both operands" do
      facts = emit_func([{:swap, {:x, 0}, {:x, 1}}])
      defs = Enum.map(facts[:def], fn [_, reg] -> reg end)
      uses = Enum.map(facts[:use], fn [_, reg] -> reg end)
      assert "x0" in defs
      assert "x1" in defs
      assert "x0" in uses
      assert "x1" in uses
    end
  end

  describe "dynamic call facts" do
    test "emits def x0 for call_fun" do
      facts = emit_func([{:call_fun, 2}])
      assert Enum.any?(facts[:def], fn [_, reg] -> reg == "x0" end)
    end

    test "emits def x0 for apply" do
      facts = emit_func([{:apply, 2}])
      assert Enum.any?(facts[:def], fn [_, reg] -> reg == "x0" end)
    end
  end

  describe "wait instructions" do
    test "wait does not crash" do
      facts = emit_func([{:wait, {:f, 5}}])
      assert Enum.any?(facts[:instruction], fn [_, _, _, op] -> op == "wait" end)
    end

    test "wait_timeout does not crash" do
      facts = emit_func([{:wait_timeout, {:f, 5}, {:integer, 1000}}])
      assert Enum.any?(facts[:instruction], fn [_, _, _, op] -> op == "wait_timeout" end)
    end
  end

  describe "float instruction facts" do
    test "emits use and def for fconv" do
      facts = emit_func([{:fconv, {:x, 0}, {:fr, 0}}])
      assert Enum.any?(facts[:use], fn [_, reg] -> reg == "x0" end)
      assert Enum.any?(facts[:def], fn [_, reg] -> reg == "fr0" end)
    end

    test "emits move, def, use for fmove" do
      facts = emit_func([{:fmove, {:fr, 0}, {:x, 0}}])
      assert [[_, "fr0", "x0"]] = facts[:move]
      assert Enum.any?(facts[:def], fn [_, reg] -> reg == "x0" end)
      assert Enum.any?(facts[:use], fn [_, reg] -> reg == "fr0" end)
    end
  end

  describe "set_tuple_element facts" do
    test "emits use for value and tuple" do
      facts = emit_func([{:set_tuple_element, {:x, 0}, {:x, 1}, 2}])
      uses = Enum.map(facts[:use], fn [_, reg] -> reg end)
      assert "x0" in uses
      assert "x1" in uses
    end
  end

  describe "update_record facts" do
    test "emits use for source and def for dest" do
      facts =
        emit_func([
          {:update_record, :update, 3, {:x, 0}, {:x, 1}, {:list, [{:integer, 1}, {:x, 2}]}}
        ])

      assert Enum.any?(facts[:use], fn [_, reg] -> reg == "x0" end)
      assert Enum.any?(facts[:def], fn [_, reg] -> reg == "x1" end)
    end
  end

  describe "bs_start_match4 facts" do
    test "emits bs_start, use, and def" do
      facts = emit_func([{:bs_start_match4, {:f, 5}, 1, {:x, 0}, {:x, 1}}])
      assert [[_, "5"]] = facts[:bs_start]
      assert Enum.any?(facts[:use], fn [_, reg] -> reg == "x0" end)
      assert Enum.any?(facts[:def], fn [_, reg] -> reg == "x1" end)
    end
  end

  describe "real module integration" do
    test "emits facts for :lists without crashing" do
      {:ok, data} = BeamSpy.BeamFile.disassemble(to_string(:code.which(:lists)))

      facts =
        Emit.emit_module(
          data.module,
          data.exports,
          [],
          data.attributes,
          data.functions
        )

      assert map_size(facts) > 0
      assert facts[:instruction] != []
      assert facts[:function_def] != []
    end

    test "emits facts for Enum without crashing" do
      {:ok, data} = BeamSpy.BeamFile.disassemble(to_string(:code.which(Enum)))

      facts =
        Emit.emit_module(
          data.module,
          data.exports,
          [],
          data.attributes,
          data.functions
        )

      assert map_size(facts) > 0
      assert facts[:instruction] != []
      assert facts[:remote_call] != []
    end

    test "emits facts for GenServer without crashing" do
      {:ok, data} = BeamSpy.BeamFile.disassemble(to_string(:code.which(GenServer)))

      facts =
        Emit.emit_module(
          data.module,
          data.exports,
          [],
          data.attributes,
          data.functions
        )

      assert map_size(facts) > 0
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
