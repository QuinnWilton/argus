defmodule Argus.EmitterTest do
  use ExUnit.Case, async: true

  alias Argus.Emitter

  # Helper to emit facts for a single function in a minimal module.
  defp emit_func(instructions, opts \\ []) do
    mod = Keyword.get(opts, :module, TestMod)
    name = Keyword.get(opts, :name, :test_func)
    arity = Keyword.get(opts, :arity, 0)
    entry = Keyword.get(opts, :entry, 1)
    exports = Keyword.get(opts, :exports, [{name, arity, entry}])

    Emitter.emit_module(
      mod,
      exports,
      [],
      [],
      [{:function, name, arity, entry, instructions}]
    )
  end

  describe "module-level facts" do
    test "emits module_info" do
      facts = Emitter.emit_module(MyMod, [], [], [], [])
      assert [["MyMod", "MyMod"]] = facts[:module_info]
    end

    test "emits function_def with exported flag" do
      facts = emit_func([{:label, 1}, :return])
      defs = facts[:function_def]
      assert length(defs) == 1
      [func_id, "TestMod", "test_func", "0", "1", "1"] = hd(defs)
      assert func_id == "TestMod:test_func/0"
    end

    test "marks non-exported functions" do
      facts =
        Emitter.emit_module(
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
      public = Enum.find(defs, fn [_, _, name, _, _, _] -> name == "public_fn" end)
      private = Enum.find(defs, fn [_, _, name, _, _, _] -> name == "private_fn" end)

      assert List.last(public) == "1"
      assert List.last(private) == "0"
    end

    test "emits import_ref" do
      facts = Emitter.emit_module(MyMod, [], [{:erlang, :+, 2}], [], [])
      assert [[":erlang", "+", "2"]] = facts[:import_ref]
    end

    test "emits module_attribute" do
      facts = Emitter.emit_module(MyMod, [], [], [behaviour: [GenServer]], [])
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
  end

  describe "call facts" do
    test "emits remote_call for call_ext" do
      facts = emit_func([{:call_ext, 2, {:extfunc, :erlang, :+, 2}}])
      assert [[_id, ":erlang", "+", "2"]] = facts[:remote_call]
    end

    test "emits tail_call for call_ext_only" do
      facts = emit_func([{:call_ext_only, 1, {:extfunc, :lists, :reverse, 1}}])
      assert [[_id]] = facts[:tail_call]
      assert [[_id, ":lists", "reverse", "1"]] = facts[:remote_call]
    end

    test "emits local_call for modern MFA-style calls" do
      facts = emit_func([{:call, 2, {MyMod, :helper, 2}}])
      assert [[_id, "MyMod:helper/2", "2"]] = facts[:local_call]
    end

    test "emits tail_call for call_only" do
      facts = emit_func([{:call_only, 2, {MyMod, :helper, 2}}])
      assert [[_id]] = facts[:tail_call]
    end

    test "emits bif_call for bif" do
      facts = emit_func([{:bif, :element, {:f, 0}, [{:integer, 2}, {:x, 0}], {:x, 0}}])
      assert [[_id, ":erlang", "element", "2", "0"]] = facts[:bif_call]
    end

    test "emits bif_call for gc_bif" do
      facts = emit_func([{:gc_bif, :+, {:f, 0}, 1, [{:x, 0}, {:integer, 1}], {:x, 0}}])
      assert [[_id, ":erlang", "+", "2", "0"]] = facts[:bif_call]
    end

    test "emits spawn_call for erlang:spawn" do
      facts = emit_func([{:call_ext, 3, {:extfunc, :erlang, :spawn, 3}}])
      assert [[_id, "dynamic", "dynamic", "3"]] = facts[:spawn_call]
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
      assert [[_id]] = facts[:send_msg]
    end

    test "emits recv_start for loop_rec" do
      facts = emit_func([{:loop_rec, {:f, 5}, {:x, 0}}])
      assert [[_id, "5"]] = facts[:recv_start]
    end

    test "emits recv_end for remove_message" do
      facts = emit_func([:remove_message])
      assert [[_id]] = facts[:recv_end]
    end
  end

  describe "exception facts" do
    test "emits try_start" do
      facts = emit_func([{:try, {:y, 0}, {:f, 10}}])
      assert [[_id, "10"]] = facts[:try_start]
    end

    test "emits try_end" do
      facts = emit_func([{:try_end, {:y, 0}}])
      assert [[_id]] = facts[:try_end]
    end
  end

  describe "make_fun facts" do
    test "emits make_fun for make_fun3 with label" do
      facts = emit_func([{:make_fun3, {:f, 15}, 0, 123, {:x, 0}, {:list, [{:x, 1}]}}])
      assert [[_id, "15", "1"]] = facts[:make_fun]
    end

    test "emits make_fun for make_fun3 with MFA" do
      facts =
        emit_func([{:make_fun3, {MyMod, :"-fun/1-", 2}, 0, 123, {:x, 0}, {:list, [{:x, 1}]}}])

      fun_facts = facts[:make_fun]
      assert [[_id, target, "1"]] = fun_facts
      assert target == "MyMod:-fun/1-/2"
    end
  end

  describe "line_info facts" do
    test "emits line_info" do
      facts = emit_func([{:line, 42}])
      assert [[_id, "42"]] = facts[:line_info]
    end
  end

  describe "real module integration" do
    test "emits facts for :lists without crashing" do
      {:ok, data} = BeamSpy.BeamFile.disassemble(to_string(:code.which(:lists)))

      facts =
        Emitter.emit_module(
          data.module,
          data.exports,
          [],
          data.attributes,
          data.functions
        )

      assert map_size(facts) > 0
      assert length(facts[:instruction]) > 0
      assert length(facts[:function_def]) > 0
    end

    test "emits facts for Enum without crashing" do
      {:ok, data} = BeamSpy.BeamFile.disassemble(to_string(:code.which(Enum)))

      facts =
        Emitter.emit_module(
          data.module,
          data.exports,
          [],
          data.attributes,
          data.functions
        )

      assert map_size(facts) > 0
      assert length(facts[:instruction]) > 0
      assert length(facts[:remote_call]) > 0
    end

    test "emits facts for GenServer without crashing" do
      {:ok, data} = BeamSpy.BeamFile.disassemble(to_string(:code.which(GenServer)))

      facts =
        Emitter.emit_module(
          data.module,
          data.exports,
          [],
          data.attributes,
          data.functions
        )

      assert map_size(facts) > 0
    end
  end
end
