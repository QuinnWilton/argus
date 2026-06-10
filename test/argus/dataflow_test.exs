defmodule Argus.DataflowTest do
  use ExUnit.Case, async: true

  alias Argus.Dataflow
  alias Argus.InstrId

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
end
