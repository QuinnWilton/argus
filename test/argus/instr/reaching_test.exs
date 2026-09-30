defmodule Argus.Instr.ReachingTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Argus.Dataflow
  alias Argus.Extractor.Helpers
  alias Argus.Instr.Reaching
  alias Argus.InstrId
  alias Argus.Pipeline.{Disassemble, Normalize}

  test "cached instruction lists distinguish integer and float literals" do
    instructions = fn value ->
      [
        {:func_info, {:atom, :m}, {:atom, :f}, 0},
        {:move, {:literal, {value}}, {:x, 0}},
        :return
      ]
    end

    integer = instructions.(1)
    float = instructions.(1.0)

    for instrs <- [integer, float, integer, float] do
      assert Reaching.at(instrs, 1) === Enum.at(instrs, 1)
      assert Reaching.sources(instrs, 2, {:x, 0}) == [1]
    end
  end

  describe "sources/3" do
    test "the last write in the block, else what reaches the block" do
      instrs = [
        {:label, 1},
        {:func_info, {:atom, :m}, {:atom, :f}, 1},
        {:label, 2},
        {:test, :is_atom, {:f, 3}, [x: 0]},
        {:move, {:atom, :a}, {:x, 1}},
        {:jump, {:f, 4}},
        {:label, 3},
        {:move, {:atom, :b}, {:x, 1}},
        {:label, 4},
        {:move, {:x, 1}, {:x, 0}},
        :return
      ]

      assert Reaching.sources(instrs, 9, {:x, 1}) == [4, 7]
      assert Reaching.sources(instrs, 4, {:x, 0}) == [{:param, 0}]
      assert Reaching.sources(instrs, 10, {:tr, {:x, 0}, :any}) == [9]
    end

    test "the parameters reach from the entry, not from code nothing reaches" do
      instrs = [
        {:label, 1},
        {:func_info, {:atom, :m}, {:atom, :f}, 1},
        {:label, 2},
        :return,
        {:label, 3},
        :return
      ]

      assert Reaching.sources(instrs, 3, {:x, 0}) == [{:param, 0}]
      assert Reaching.sources(instrs, 5, {:x, 0}) == []
    end
  end

  describe "export/1 and restore/2" do
    test "another process answers from the restored solutions as from its own" do
      {:ok, data} = Disassemble.disassemble_path(to_string(:code.which(:gen_server)))
      fresh = Reaching.uses(data.module, data.functions)
      exported = Reaching.export(data.functions)

      probes =
        for {:function, _, _, _, instrs} <- data.functions,
            idx <- 0..(length(instrs) - 1)//7,
            reg <- [{:x, 0}, {:x, 1}, {:y, 0}],
            do: {instrs, idx, reg}

      answers = for {instrs, idx, reg} <- probes, do: Reaching.sources(instrs, idx, reg)

      # A copy of the instruction lists, as a kept base holds them.
      copy = :erlang.binary_to_term(:erlang.term_to_binary({data.functions, exported}))

      task =
        Task.async(fn ->
          {functions, exported} = copy
          :ok = Reaching.restore(functions, exported)
          restored = Reaching.uses(data.module, functions)

          restored_answers =
            for {:function, _, _, _, instrs} <- functions,
                idx <- 0..(length(instrs) - 1)//7,
                reg <- [{:x, 0}, {:x, 1}, {:y, 0}],
                do: Reaching.sources(instrs, idx, reg)

          {restored, restored_answers, Process.get(:argus_instr_reaching)}
        end)

      {restored, restored_answers, kept} = Task.await(task)
      assert restored == fresh
      assert restored_answers == answers
      # Every function answered from what was restored, none solved anew.
      {_module, functions} = kept

      assert Enum.all?(functions, fn {_key, [{_instrs, solution}]} -> solution.skeleton == nil end)
    end
  end

  describe "agreement with Argus.Dataflow" do
    @modules [:lists, :gen_server, :proc_lib, :beam_ssa_codegen, Enum, GenServer, Registry] ++
               [Argus.Test.Fixtures.Instr]

    property "every read the facts record has the same writers, raw or normalized" do
      functions =
        for mod <- @modules,
            {:ok, data} = Disassemble.disassemble_path(to_string(:code.which(mod))),
            reaching = Dataflow.reaching_uses(Helpers.typed(data), params: true),
            by_function =
              Enum.group_by(reaching, fn {_source, _reg, use} -> {use.func, use.arity} end),
            {:function, name, arity, _, _} = function <- data.functions,
            reads = Map.get(by_function, {to_string(name), arity}, []),
            do: {mod, function, Enum.group_by(reads, &use_key/1, &source_of/1)}

      check all(
              {mod, {:function, _, _, _, raw} = function, reads} <- member_of(functions),
              max_runs: Argus.Test.Runs.max_runs(50, 150)
            ) do
        normalized = mod |> Normalize.normalize_function(function) |> Enum.map(&elem(&1, 1))

        for {{_f, _a, idx, reg}, sources} <- reads, instrs <- [raw, normalized] do
          assert Reaching.sources(instrs, idx, parse_reg(reg)) == Enum.sort(sources),
                 "#{inspect(mod)} #{inspect(Enum.at(raw, idx))} #{reg}"
        end
      end
    end
  end

  describe "uses/2" do
    test "is Dataflow.reaching_uses/2 with the parameters, from the instruction lists" do
      for mod <- [:lists, :gen_server, GenServer, Argus.Test.Fixtures.Instr] do
        {:ok, data} = Disassemble.disassemble_path(to_string(:code.which(mod)))

        assert Reaching.uses(data.module, data.functions) ==
                 Dataflow.reaching_uses(Helpers.typed(data), params: true),
               inspect(mod)
      end
    end

    test "a function's normalized list and its raw one are solved once" do
      {:ok, data} = Disassemble.disassemble_path(to_string(:code.which(:lists)))

      {raw, normalized} =
        Enum.find_value(data.functions, fn {:function, _, _, _, raw} = function ->
          normalized = :lists |> Normalize.normalize_function(function) |> Enum.map(&elem(&1, 1))
          if normalized != raw and length(raw) > 20, do: {raw, normalized}
        end)

      Process.delete(:argus_instr_reaching)
      Reaching.sources(normalized, 0, {:x, 0})
      Reaching.sources(raw, 0, {:x, 0})
      {{:atom, :lists}, cached} = Process.get(:argus_instr_reaching)
      [[{^raw, second}, {^normalized, first}]] = Map.values(cached)

      assert :erts_debug.same(second.blocks, first.blocks)
      assert Reaching.at(raw, 3) == Enum.at(raw, 3)
      assert Reaching.at(normalized, 3) == Enum.at(normalized, 3)
    end
  end

  defp use_key({_source, reg, %InstrId{func: f, arity: a, idx: idx}}), do: {f, a, idx, reg}
  defp source_of({{:param, k}, _reg, _use}), do: {:param, k}
  defp source_of({%InstrId{idx: idx}, _reg, _use}), do: idx

  defp parse_reg("x" <> n), do: {:x, String.to_integer(n)}
  defp parse_reg("y" <> n), do: {:y, String.to_integer(n)}
  defp parse_reg("fr" <> n), do: {:fr, String.to_integer(n)}
end
