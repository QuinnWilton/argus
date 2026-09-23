defmodule Argus.DataflowTest do
  use ExUnit.Case, async: true

  alias Argus.Dataflow
  alias Argus.Extractor.Helpers
  alias Argus.InstrId
  alias Argus.Pipeline.Disassemble
  alias Argus.Test.Fixtures.Instr, as: Fixture

  # Build a typed fact base for one function from a compact spec:
  # {op, defs, uses, control} where control is nil | {:branch, label} |
  # {:jump, label} | {:label, n} | :return.
  defp facts_for(specs, func \\ "f") do
    rows = Enum.with_index(specs)

    instruction =
      for {{op, _defs, _uses, _ctl}, idx} <- rows,
          do: %{id: iid(func, idx), func: "M:#{func}/1", idx: idx, op: to_string(op)}

    defs =
      for {{_op, defs, _uses, _ctl}, idx} <- rows,
          reg <- defs,
          do: %{id: iid(func, idx), reg: reg}

    uses =
      for {{_op, _defs, uses, _ctl}, idx} <- rows,
          reg <- uses,
          do: %{id: iid(func, idx), reg: reg}

    next =
      for {{op, _d, _u, _ctl}, idx} <- rows,
          op not in [:return, :jump],
          idx + 1 < length(specs),
          do: %{from: iid(func, idx), to: iid(func, idx + 1)}

    labels =
      for {{_op, _d, _u, {:label, n}}, idx} <- rows,
          do: %{label: n, id: iid(func, idx)}

    branches =
      for {{_op, _d, _u, {:branch, n}}, idx} <- rows,
          do: %{id: iid(func, idx), fail: n, reserved: 0}

    jumps =
      for {{_op, _d, _u, {:jump, n}}, idx} <- rows,
          do: %{id: iid(func, idx), target: n}

    %{
      instruction: instruction,
      def: defs,
      use: uses,
      next: next,
      label_at: labels,
      branch: branches,
      jump: jumps
    }
  end

  defp iid(func, idx), do: %InstrId{module: "M", func: func, arity: 1, idx: idx}

  defp edges(facts) do
    facts
    |> Dataflow.def_use_edges()
    |> MapSet.new(fn {d, u} -> {d.func, d.idx, u.idx} end)
  end

  defp merge(left, right) do
    Map.merge(left, right, fn _k, l, r -> l ++ r end)
  end

  test "straight-line def reaches its use; a redefinition kills it" do
    facts =
      facts_for([
        # 0: x0 := literal
        {:move, ["x0"], [], nil},
        # 1: reads x0 (edge 0 -> 1), then x0 := result
        {:gc_bif, ["x0"], ["x0"], nil},
        # 2: reads x0 — only the redefinition at 1 reaches
        {:return, [], ["x0"], :return}
      ])

    assert edges(facts) == MapSet.new([{"f", 0, 1}, {"f", 1, 2}])
  end

  test "both branch arms' definitions reach the join" do
    facts =
      facts_for([
        # 0: x0 := a
        {:move, ["x0"], [], nil},
        # 1: test, fail -> label 10 (instr 4); reads x0
        {:is_ge, [], ["x0"], {:branch, 10}},
        # 2: pass arm redefines x0 (kills 0 on this path)
        {:move, ["x0"], [], nil},
        # 3: jump to the join (label 20, instr 6)
        {:jump, [], [], {:jump, 20}},
        # 4: fail arm label — def 0 still reaches here
        {:label, [], [], {:label, 10}},
        # 5: reads x0 on the fail arm (edge 0 -> 5)
        {:gc_bif, ["x1"], ["x0"], nil},
        # 6: join label
        {:label, [], [], {:label, 20}},
        # 7: reads x0 at the join — defs 0 (fail path) and 2 (pass path)
        {:return, [], ["x0"], :return}
      ])

    e = edges(facts)
    assert {"f", 0, 1} in e
    assert {"f", 0, 5} in e
    assert {"f", 0, 7} in e
    assert {"f", 2, 7} in e
    # the pass-arm redefinition never flows backward into the fail arm.
    refute {"f", 2, 5} in e
  end

  test "a loop feeds an instruction's definition back to its own use" do
    facts =
      facts_for([
        # 0: x0 := 0
        {:move, ["x0"], [], nil},
        # 1: loop header
        {:label, [], [], {:label, 30}},
        # 2: x0 := x0 + 1 — reads both the initial def and itself via the back edge
        {:gc_bif, ["x0"], ["x0"], nil},
        # 3: loop test, fail -> header
        {:is_lt, [], ["x0"], {:branch, 30}},
        # 4: reads the final counter
        {:return, [], ["x0"], :return}
      ])

    e = edges(facts)
    assert {"f", 0, 2} in e
    assert {"f", 2, 2} in e
    assert {"f", 2, 4} in e
    # the initial def is killed by 2 before reaching the exit read.
    refute {"f", 0, 4} in e
  end

  test "a use at a defining instruction reads the state before its own write" do
    facts =
      facts_for([
        {:move, ["x0"], [], nil},
        # swap-like: reads and writes x0 in one instruction.
        {:swap, ["x0"], ["x0"], nil},
        {:return, [], ["x0"], :return}
      ])

    e = edges(facts)
    assert {"f", 0, 1} in e
    refute {"f", 1, 1} in e
  end

  test "functions are isolated: no cross-function edges" do
    facts =
      merge(
        facts_for([{:move, ["x0"], [], nil}, {:return, [], ["x0"], :return}], "a"),
        facts_for([{:return, [], ["x0"], :return}], "b")
      )

    e = edges(facts)
    assert {"a", 0, 1} in e
    # b's read of x0 has no reaching definition anywhere.
    refute Enum.any?(e, fn {func, _d, _u} -> func == "b" end)
  end

  test "empty facts produce no edges" do
    assert Dataflow.def_use_edges(%{}) == MapSet.new()
  end

  describe "reaching_uses/2" do
    defp reaching(facts, opts) do
      facts
      |> Dataflow.reaching_uses(opts)
      |> MapSet.new(fn {source, reg, use} -> {source_of(source), reg, use.idx} end)
    end

    defp source_of({:param, k}), do: {:param, k}
    defp source_of(%InstrId{idx: idx}), do: idx

    test "a read no instruction wrote resolves to the parameter, when asked" do
      facts =
        facts_for([
          # 0: reads x0 (parameter 0), writes x1
          {:gc_bif, ["x1"], ["x0"], nil},
          # 1: reads x1
          {:return, [], ["x1"], :return}
        ])

      assert reaching(facts, params: true) == MapSet.new([{{:param, 0}, "x0", 0}, {0, "x1", 1}])
      assert reaching(facts, []) == MapSet.new([{0, "x1", 1}])
    end

    test "a read fed by a write on one path and the parameter on the other keeps both" do
      facts =
        facts_for([
          # 0: test x0; fail -> label 5
          {:test, [], ["x0"], {:branch, 5}},
          # 1: x0 := literal on the pass path
          {:move, ["x0"], [], nil},
          # 2: -> label 6
          {:jump, [], [], {:jump, 6}},
          # 3: label 5, falls through to 4
          {:label, [], [], {:label, 5}},
          # 4: label 6, the join
          {:label, [], [], {:label, 6}},
          # 5: reads x0: written at 1, or still the parameter
          {:return, [], ["x0"], :return}
        ])

      assert reaching(facts, params: true) ==
               MapSet.new([{{:param, 0}, "x0", 0}, {1, "x0", 5}, {{:param, 0}, "x0", 5}])
    end

    test "each edge carries the register it travels in" do
      facts =
        facts_for([
          # 0: get_map_elements: reads x0, writes x2 and x3
          {:get_map_elements, ["x2", "x3"], ["x0"], nil},
          # 1: reads x3
          {:move, ["x4"], ["x3"], nil},
          # 2: reads x2
          {:return, [], ["x2"], :return}
        ])

      assert reaching(facts, params: true) ==
               MapSet.new([{{:param, 0}, "x0", 0}, {0, "x3", 1}, {0, "x2", 2}])
    end

    test "def_use_edges/1 is the same relation without registers or parameters" do
      facts =
        facts_for([
          {:get_map_elements, ["x2", "x3"], ["x0"], nil},
          {:move, ["x4"], ["x3"], nil},
          {:return, [], ["x2"], :return}
        ])

      assert edges(facts) == MapSet.new([{"f", 0, 1}, {"f", 0, 2}])
    end
  end

  describe "control the facts carry besides next, jump and branch" do
    defp reaching_in(module, name) do
      {:ok, data} = Disassemble.disassemble_path(to_string(:code.which(module)))
      instrs = for {:function, ^name, _, _, instrs} <- data.functions, do: instrs

      triples =
        for {source, reg, %InstrId{func: func} = use} <-
              Dataflow.reaching_uses(Helpers.typed(data), params: true),
            func == to_string(name),
            do: {source_of(source), reg, use.idx}

      {List.flatten(instrs), MapSet.new(triples)}
    end

    defp index_of(instrs, pattern), do: Enum.find_index(instrs, pattern)

    test "a rescue's class and reason are try_case's writes, not the parameters" do
      {instrs, triples} = reaching_in(Fixture, :handler)
      try_case = index_of(instrs, &match?({:try_case, _}, &1))

      # The only reads of a parameter are the protected call's arguments.
      assert for({{:param, _}, _reg, use} <- triples, do: use) |> Enum.uniq() ==
               [index_of(instrs, &match?({:call_ext, 2, {:extfunc, :ets, :lookup, 2}}, &1))]

      assert Enum.any?(triples, &match?({^try_case, "x1", _}, &1))
    end

    test "a value bound before the try reaches the handler along the exception edge" do
      {instrs, triples} = reaching_in(Fixture, :fallback)
      tuple = index_of(instrs, &match?({:put_tuple2, _, {:list, [{:y, _}, _]}}, &1))
      {:put_tuple2, _, {:list, [{:y, n}, _]}} = Enum.at(instrs, tuple)

      writers =
        for {source, reg, ^tuple} <- triples, reg == "y#{n}", do: Enum.at(instrs, source)

      assert Enum.sort(writers) ==
               Enum.sort([{:move, {:atom, :one}, {:y, n}}, {:move, {:atom, :other}, {:y, n}}])
    end

    test "a block only a guard BIF's fail label reaches still gets the writes before it" do
      facts =
        facts_for([
          {:move, ["x1"], [], nil},
          {:bif, ["x2"], ["x0"], nil},
          {:return, [], ["x2"], :return},
          {:label, [], [], {:label, 9}},
          {:return, [], ["x1"], :return}
        ])

      facts = Map.put(facts, :bif_call, [%{id: iid("f", 1), fail: 9}])
      assert {"f", 0, 4} in edges(facts)
    end

    test "only the entry starts from the parameters, not code nothing reaches" do
      facts =
        facts_for([
          {:return, [], ["x0"], :return},
          {:label, [], [], {:label, 9}},
          {:return, [], ["x0"], :return}
        ])

      assert reaching(facts, params: true) == MapSet.new([{{:param, 0}, "x0", 0}])
    end

    test "the entry label from function_entry is where the parameters start" do
      facts =
        facts_for([
          {:label, [], [], {:label, 1}},
          {:func_info, [], [], nil},
          {:label, [], [], {:label, 2}},
          {:return, [], ["x0"], :return}
        ])

      assert reaching(facts, params: true) == MapSet.new([{{:param, 0}, "x0", 3}])

      with_entry = Map.put(facts, :function_entry, [%{func: "M:f/1", entry: 2}])
      assert reaching(with_entry, params: true) == MapSet.new([{{:param, 0}, "x0", 3}])
    end
  end
end
