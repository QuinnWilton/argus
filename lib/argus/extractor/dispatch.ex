defmodule Argus.Extractor.Dispatch do
  @moduledoc """
  How a multi-clause function chooses a clause, read from its bytecode.

  A multi-clause function raises `FunctionClauseError` by jumping to its
  own `func_info` label, so the tests whose failure edge points there are
  clause selection, and a function with no such edge accepts every
  argument. The atoms those tests compare a register against are the
  values the function discriminates on. Four extractors kept private
  copies of these readings; this is the one.
  """

  @doc "The label of the function's `func_info` instruction, or `nil`."
  @spec func_info_label([tuple()]) :: non_neg_integer() | nil
  def func_info_label(instrs) do
    case Enum.find_index(instrs, &match?({:func_info, _, _, _}, &1)) do
      nil -> nil
      0 -> nil
      idx -> with {:label, l} <- Enum.at(instrs, idx - 1), do: l, else: (_ -> nil)
    end
  end

  @doc """
  Where execution begins: the instruction after `func_info`, not index
  zero, which is the failure landing pad.
  """
  @spec entry_index([tuple()]) :: non_neg_integer()
  def entry_index(instrs) do
    case Enum.find_index(instrs, &match?({:func_info, _, _, _}, &1)) do
      nil -> 0
      idx -> idx + 1
    end
  end

  @doc "Every `{:f, label}` operand of an instruction."
  @spec branch_targets(tuple()) :: [non_neg_integer()]
  def branch_targets(instr), do: collect_f(instr, [])

  defp collect_f({:f, l}, acc) when is_integer(l) and l > 0, do: [l | acc]

  defp collect_f(term, acc) when is_tuple(term),
    do: term |> Tuple.to_list() |> Enum.reduce(acc, &collect_f/2)

  defp collect_f(term, acc) when is_list(term), do: Enum.reduce(term, acc, &collect_f/2)
  defp collect_f(_term, acc), do: acc

  @doc """
  Whether some clause accepts every argument: nothing branches to the
  `func_info` label. Guards fall out correctly, since a guarded catch-all
  compiles to a test whose failure branch is that label.
  """
  @spec total?([tuple()]) :: boolean()
  def total?(instrs) do
    case func_info_label(instrs) do
      nil -> false
      label -> not Enum.any?(instrs, &(label in branch_targets(&1)))
    end
  end

  @doc """
  The literal atoms the function compares `register` against — in
  `is_eq_exact` tests, `is_tagged_tuple` tests (the tag) and `select_val`
  tables — or against any register when `:any`. Over-approximated on
  purpose: every comparison anywhere in the body counts, and consumers
  ask which values are NOT handled.
  """
  @spec compared_atoms([tuple()], {:x, non_neg_integer()} | :any) :: [atom()]
  def compared_atoms(instrs, register) do
    instrs
    |> Enum.flat_map(&atoms_compared(&1, register))
    |> Enum.uniq()
  end

  defp atoms_compared({:test, :is_eq_exact, _f, [a, b]}, register) do
    cond do
      register == :any -> atoms_in([a, b])
      reg(a) == register -> atoms_in([b])
      reg(b) == register -> atoms_in([a])
      true -> []
    end
  end

  defp atoms_compared({:test, :is_tagged_tuple, _f, [src, _arity, tag]}, register) do
    if register == :any or reg(src) == register, do: atoms_in([tag]), else: []
  end

  defp atoms_compared({:select_val, src, _f, {:list, entries}}, register) do
    if register == :any or reg(src) == register, do: atoms_in(entries), else: []
  end

  defp atoms_compared(_instr, _register), do: []

  defp atoms_in(list), do: for({:atom, a} <- list, is_atom(a), do: a)

  @doc """
  Where execution continues once `register` has been established equal to
  `atom`: the instruction after an `is_eq_exact` against it, or the label
  `select_val` pairs with it. Resolved to instruction indices via
  `labels` (label → index).
  """
  @spec continuations_after([tuple()], {:x, non_neg_integer()}, atom(), %{
          non_neg_integer() => non_neg_integer()
        }) :: [non_neg_integer()]
  def continuations_after(instrs, register, atom, labels) do
    instrs
    |> Enum.with_index()
    |> Enum.flat_map(fn
      {{:test, :is_eq_exact, _f, [a, b]}, idx} ->
        if {reg(a), b} == {register, {:atom, atom}} or {a, reg(b)} == {{:atom, atom}, register},
          do: [idx + 1],
          else: []

      {{:select_val, src, _f, {:list, entries}}, _idx} ->
        if reg(src) == register, do: arm_targets(entries, atom, labels), else: []

      _ ->
        []
    end)
  end

  defp arm_targets([{:atom, atom}, {:f, l} | rest], atom, labels),
    do: List.wrap(Map.get(labels, l)) ++ arm_targets(rest, atom, labels)

  defp arm_targets([_value, _target | rest], atom, labels), do: arm_targets(rest, atom, labels)
  defp arm_targets(_other, _atom, _labels), do: []

  @doc "Label → instruction index for the function."
  @spec labels([tuple()]) :: %{non_neg_integer() => non_neg_integer()}
  def labels(instrs) do
    for {{:label, l}, idx} <- Enum.with_index(instrs), into: %{}, do: {l, idx}
  end

  defp reg({:tr, r, _type}), do: reg(r)
  defp reg({:x, _} = r), do: r
  defp reg({:y, _} = r), do: r
  defp reg(_other), do: nil
end
