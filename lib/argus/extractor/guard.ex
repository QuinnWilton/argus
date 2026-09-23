defmodule Argus.Extractor.Guard do
  @moduledoc """
  Whether one instruction is decided by a test of another's result.

  A check-then-act race is a lookup whose result decides whether a
  creating operation runs: `case whereis(name) do nil -> start(...)`.
  Two questions make it: which instruction tests the lookup's result
  (`result_test/2`), and whether the act is control-dependent on that
  test (`decides?/3`). Both are computed here, in Elixir, because branch
  structure is invisible to the rules — `branch`, `select_branch` and
  `label_at` are in-process relations — and `conditional_call` is too
  coarse: it says an act depends on *some* branch, which every `case`
  around a start satisfies with no lookup in sight.

  Which side of the test the act sits on is deliberately not asked. An
  act on the "found" side is nonsense code, and reporting it is right.

  Deprecated: the check-then-act rules read `Argus.Extractors.Dependence`,
  whose summaries answer the same question across functions and through
  data as well as control. Nothing in argus calls this module.
  """

  alias Argus.Cfg.Function

  import Argus.Extractor.Helpers, only: [register: 1]

  @typedoc "An index into a function's instruction list."
  @type index :: non_neg_integer()

  @doc """
  The index of the first test on the result of the call at `idx` — or on
  a projection of it, so `[{pid, _}] = Registry.lookup(...)` counts — in
  the straight-line code after the call. `:no` when the result reaches a
  label, a call or a return untested.
  """
  @deprecated "Use Argus.Extractors.Dependence (site_depends) instead"
  @spec result_test([tuple()], index()) :: {:ok, index()} | :no
  def result_test(instrs, idx) do
    instrs
    |> Enum.drop(idx + 1)
    |> Enum.with_index(idx + 1)
    |> walk([{:x, 0}])
  end

  defp walk([], _regs), do: :no

  defp walk([{instr, i} | rest], regs) do
    case step(instr, regs) do
      :test -> {:ok, i}
      :stop -> :no
      {:continue, regs} -> walk(rest, regs)
    end
  end

  # One instruction's effect on the set of registers holding the result.
  defp step({:line, _}, regs), do: {:continue, regs}
  defp step({:test_heap, _, _}, regs), do: {:continue, regs}
  defp step({:allocate, _, _}, regs), do: {:continue, regs}
  defp step({:allocate_heap, _, _, _}, regs), do: {:continue, regs}
  defp step({:init_yregs, _}, regs), do: {:continue, regs}
  defp step({:move, src, dst}, regs), do: {:continue, moved(regs, register(src), register(dst))}

  defp step({:get_tuple_element, src, _n, dst}, regs),
    do: {:continue, projected(regs, src, [dst])}

  defp step({:get_hd, src, dst}, regs), do: {:continue, projected(regs, src, [dst])}
  defp step({:get_tl, src, dst}, regs), do: {:continue, projected(regs, src, [dst])}
  defp step({:get_list, src, hd, tl}, regs), do: {:continue, projected(regs, src, [hd, tl])}
  defp step({:test, _op, _fail, args}, regs) when is_list(args), do: tested(args, regs)
  defp step({:test, _op, _fail, _live, args}, regs) when is_list(args), do: tested(args, regs)

  defp step({:test, _op, _fail, _live, args, _dst}, regs) when is_list(args),
    do: tested(args, regs)

  defp step({:select_val, reg, _fail, _cases}, regs), do: selected(reg, regs)
  defp step({:select_tuple_arity, reg, _fail, _cases}, regs), do: selected(reg, regs)
  defp step({:label, _}, _regs), do: :stop
  defp step(:return, _regs), do: :stop
  defp step({:jump, _}, _regs), do: :stop
  defp step(instr, regs), do: if(call?(instr), do: :stop, else: {:continue, regs})

  defp tested(args, regs) do
    if Enum.any?(args, &(register(&1) in regs)), do: :test, else: {:continue, regs}
  end

  defp selected(reg, regs) do
    if register(reg) in regs, do: :test, else: {:continue, regs}
  end

  defp moved(regs, src, dst) do
    cond do
      src in regs -> Enum.uniq([dst | regs])
      dst in regs -> List.delete(regs, dst)
      true -> regs
    end
  end

  defp projected(regs, src, dsts) do
    dsts = Enum.map(dsts, &register/1)

    if register(src) in regs,
      do: Enum.uniq(dsts ++ regs),
      else: Enum.reject(regs, &(&1 in dsts))
  end

  defp call?(instr) when is_tuple(instr) and tuple_size(instr) > 0 do
    elem(instr, 0) in [
      :call,
      :call_only,
      :call_last,
      :call_ext,
      :call_ext_only,
      :call_ext_last,
      :call_fun,
      :call_fun2,
      :apply,
      :apply_last
    ]
  end

  defp call?(_instr), do: false

  @doc """
  Whether the instruction at `act_idx` runs only because of the test at
  `test_idx`: its block is control-dependent on the test's block,
  directly or through the blocks between (`case whereis(...) do nil ->
  case start(...) do ... end end`).
  """
  @deprecated "Use Argus.Extractors.Dependence (site_depends) instead"
  @spec decides?(Function.t(), index(), index()) :: boolean()
  def decides?(%Function{} = fun, test_idx, act_idx) do
    with %{id: test_block} <- Function.block_at(fun, test_idx),
         %{id: act_block} <- Function.block_at(fun, act_idx) do
      deciders(Function.control_deps(fun), [act_block], MapSet.new([act_block]), test_block)
    else
      _ -> false
    end
  end

  defp deciders(_deps, [], _seen, _test_block), do: false

  defp deciders(deps, [block | rest], seen, test_block) do
    direct = Map.get(deps, block, [])

    if test_block in direct do
      true
    else
      unseen = Enum.reject(direct, &MapSet.member?(seen, &1))
      deciders(deps, rest ++ unseen, MapSet.union(seen, MapSet.new(unseen)), test_block)
    end
  end
end
