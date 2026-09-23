defmodule Argus.Instr.ReachingTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Argus.Dataflow
  alias Argus.Extractor.Helpers
  alias Argus.Instr.Reaching
  alias Argus.InstrId
  alias Argus.Pipeline.{Disassemble, Normalize}

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

  describe "agreement with Argus.Dataflow" do
    @modules [:lists, :gen_server, :proc_lib, :beam_ssa_codegen, Enum, GenServer, Registry] ++
               [Argus.Test.Fixtures.Instr]

    property "every read the facts record has the same writers, raw or normalized" do
      functions =
        for mod <- @modules,
            {:ok, data} = Disassemble.disassemble_path(to_string(:code.which(mod))),
            reaching = Dataflow.reaching_uses(Helpers.typed(data), params: true),
            by_use = Enum.group_by(reaching, &use_key/1, &source_of/1),
            {:function, name, arity, _, _} = function <- data.functions,
            do:
              {mod, function,
               Map.filter(by_use, fn {{f, a, _, _}, _} -> {f, a} == {to_string(name), arity} end)}

      check all(
              {mod, {:function, _, _, _, raw} = function, reads} <- member_of(functions),
              max_runs: 150
            ) do
        normalized = mod |> Normalize.normalize_function(function) |> Enum.map(&elem(&1, 1))

        for {{_f, _a, idx, reg}, sources} <- reads, instrs <- [raw, normalized] do
          assert Reaching.sources(instrs, idx, parse_reg(reg)) == Enum.sort(sources),
                 "#{inspect(mod)} #{inspect(Enum.at(raw, idx))} #{reg}"
        end
      end
    end
  end

  defp use_key({_source, reg, %InstrId{func: f, arity: a, idx: idx}}), do: {f, a, idx, reg}
  defp source_of({{:param, k}, _reg, _use}), do: {:param, k}
  defp source_of({%InstrId{idx: idx}, _reg, _use}), do: idx

  defp parse_reg("x" <> n), do: {:x, String.to_integer(n)}
  defp parse_reg("y" <> n), do: {:y, String.to_integer(n)}
  defp parse_reg("fr" <> n), do: {:fr, String.to_integer(n)}
end
