defmodule Argus.Extractors.ErrorHandling.ClauseHead do
  @moduledoc """
  The atom a function clause's head matched its first argument against,
  for an instruction inside that clause.

  `def handle_info(:heartbeat, state)` compiles to a test of `x0`
  against `:heartbeat` (`is_eq_exact`, or an arm of a `select_val` when
  several atom clauses share a dispatch) whose passing edge leads into
  the clause body. An instruction in the body is dominated by that edge,
  so walking the dominator tree up from the instruction's block finds
  the test. The walk only trusts a test whose `x0` is still the
  argument: every block from the function's entry down to the test does
  nothing but dispatch (labels, line markers, tests, selects, jumps), so
  nothing has overwritten the register.
  """

  alias Argus.Cfg.Function, as: CfgFunction

  @dispatch_ops [:label, :line, :func_info, :test, :select_val, :select_tuple_arity, :jump]

  @doc """
  The atom the clause holding instruction `idx` matched `x0` against,
  inspected, or `nil` when no head test dominates it.
  """
  @spec atom_at(CfgFunction.t(), [tuple()], non_neg_integer()) :: String.t() | nil
  def atom_at(%CfgFunction{} = fun, instrs, idx) do
    instrs = List.to_tuple(instrs)

    case CfgFunction.block_at(fun, idx) do
      nil -> nil
      block -> fun |> chain(block.id, []) |> find(fun, instrs)
    end
  end

  # The dominator chain from the entry down to the block, entry first.
  defp chain(fun, id, acc) do
    case Map.fetch(fun.idom, id) do
      {:ok, parent} when parent != id -> chain(fun, parent, [id | acc])
      _entry -> [id | acc]
    end
  end

  # Down the chain from the entry: the last head test before the block,
  # as long as every block above it only dispatches.
  defp find([parent, child | rest], fun, instrs) do
    parent_block = Map.fetch!(fun.blocks, parent)

    cond do
      not dispatch_only?(parent_block, instrs) ->
        nil

      atom = passing_atom(parent_block, Map.fetch!(fun.blocks, child), instrs) ->
        find([child | rest], fun, instrs) || atom

      true ->
        find([child | rest], fun, instrs)
    end
  end

  defp find(_last, _fun, _instrs), do: nil

  defp dispatch_only?(%{range: {first, last}}, instrs) do
    Enum.all?(first..last//1, fn i -> elem(elem(instrs, i), 0) in @dispatch_ops end)
  end

  # The atom whose test passes from `parent` into `child`, if any.
  defp passing_atom(%{range: {_, last}, succs: succs}, child, instrs) do
    edge = Enum.find_value(succs, fn {id, kind} -> if id == child.id, do: kind end)

    case {elem(instrs, last), edge} do
      {{:test, :is_eq_exact, _fail, [a, b]}, :branch_pass} ->
        x0_atom(a, b) || x0_atom(b, a)

      {{:select_val, reg, _fail, {:list, arms}}, {:select_arm, _}} ->
        if x0?(reg), do: arm_atom(arms, child.label)

      _other ->
        nil
    end
  end

  defp x0_atom(reg, {:atom, atom}), do: if(x0?(reg), do: inspect(atom))
  defp x0_atom(_reg, _value), do: nil

  defp arm_atom(arms, label) do
    arms
    |> Enum.chunk_every(2)
    |> Enum.find_value(fn
      [{:atom, atom}, {:f, ^label}] -> inspect(atom)
      _other -> nil
    end)
  end

  defp x0?({:x, 0}), do: true
  defp x0?({:tr, reg, _type}), do: x0?(reg)
  defp x0?(_reg), do: false
end
