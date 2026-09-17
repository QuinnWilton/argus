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
  Whether some clause accepts every value of `register` — the message
  argument of a callback — whatever it demands of the other arguments.

  `handle_info(msg, {stack, continuation})` is a catch-all for messages
  even though its head tests the state; `total?/1` would say no, since
  the state pattern can branch to `func_info`. The scan walks the clause
  heads in order: a clause begins at the entry or at the fail label of a
  head test, and it is total on `register` if its head tests nothing
  read from `register` (or a register copied or projected from it)
  before the body starts. Guards on the message count as tests; guards
  on the state do not.
  """
  @spec total_on?([tuple()], {:x, non_neg_integer()}) :: boolean()
  def total_on?(instrs, register) do
    entry = func_info_label(instrs)
    initial = %{tracked: MapSet.new([register]), tested: false, body: false, heads: MapSet.new()}

    {found?, _} =
      Enum.reduce_while(instrs, {false, initial}, fn instr, {_, state} ->
        case head_step(instr, state, register, entry) do
          :total -> {:halt, {true, state}}
          state -> {:cont, {false, state}}
        end
      end)

    found?
  end

  # A clause boundary: the entry label, or the fail label of a head test.
  # A test inside a body branches too, but its fail label is a branch
  # within that body, not the next clause: only head tests add heads.
  defp head_step({:label, l}, state, register, entry) do
    if l == entry or MapSet.member?(state.heads, l),
      do: %{state | tracked: MapSet.new([register]), tested: false, body: false},
      else: state
  end

  defp head_step({:test, _op, {:f, l}, args}, state, _register, entry) when is_list(args) do
    head_test(state, Enum.any?(args, &tracked?(&1, state.tracked)), l, entry)
  end

  defp head_step({:test, _op, {:f, l}, src, _fields}, state, _register, entry) do
    head_test(state, tracked?(src, state.tracked), l, entry)
  end

  defp head_step({op, src, {:f, l}, _list}, state, _register, entry)
       when op in [:select_val, :select_tuple_arity] do
    head_test(state, tracked?(src, state.tracked), l, entry)
  end

  defp head_step({:move, src, dst}, state, _register, _entry),
    do: %{state | tracked: track(state.tracked, src, dst)}

  defp head_step({:get_tuple_element, src, _i, dst}, state, _register, _entry),
    do: %{state | tracked: track(state.tracked, src, dst)}

  defp head_step({:get_hd, src, dst}, state, _register, _entry),
    do: %{state | tracked: track(state.tracked, src, dst)}

  defp head_step({:get_tl, src, dst}, state, _register, _entry),
    do: %{state | tracked: track(state.tracked, src, dst)}

  # Bookkeeping the compiler emits between a head and its body.
  defp head_step({:line, _}, state, _register, _entry), do: state
  defp head_step({:func_info, _, _, _}, state, _register, _entry), do: state
  defp head_step({:allocate, _, _}, state, _register, _entry), do: state
  defp head_step({:allocate_heap, _, _, _}, state, _register, _entry), do: state
  defp head_step({:allocate_zero, _, _}, state, _register, _entry), do: state
  defp head_step({:init_yregs, _}, state, _register, _entry), do: state
  defp head_step({:test_heap, _, _}, state, _register, _entry), do: state
  defp head_step({:trim, _, _}, state, _register, _entry), do: state

  # Anything else is the body: the clause is entered.
  defp head_step(_instr, state, _register, _entry) do
    cond do
      state.body -> state
      state.tested -> %{state | body: true}
      true -> :total
    end
  end

  # Which fail labels start the next clause: those of tests on the
  # message. A test on another argument before the body is either a head
  # pattern on the state — its fail label is func_info, never jumped to
  # — or the first instruction of the body (`state.acks` compiles to
  # `is_map` with a fallback branch), whose fail label is a branch within
  # this clause. Neither opens a clause.
  defp head_test(%{body: true} = state, _tested?, _label, _entry), do: state

  defp head_test(state, tested?, label, entry) do
    heads = if tested? or label == entry, do: MapSet.put(state.heads, label), else: state.heads
    %{state | tested: state.tested or tested?, heads: heads}
  end

  defp track(tracked, src, dst) do
    case {reg(src), reg(dst)} do
      {nil, _} ->
        tracked

      {_, nil} ->
        tracked

      {s, d} ->
        if MapSet.member?(tracked, s), do: MapSet.put(tracked, d), else: MapSet.delete(tracked, d)
    end
  end

  defp tracked?(operand, tracked) do
    case reg(operand) do
      nil -> false
      r -> MapSet.member?(tracked, r)
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
