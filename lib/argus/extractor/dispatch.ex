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
  the state pattern can branch to `func_info`. The walk follows every
  path from the entry through the clause heads — both edges of each
  test, every `select` arm, jumps — carrying the registers that hold the
  message (or a copy or projection of it) and whether the path has
  tested one of them. A path that reaches a body instruction without
  having tested the message is a clause that accepts every message.
  Bodies are not entered: a test inside one branches within that body,
  not to another clause. Guards on the message count as tests; guards
  on the state do not.
  """
  @spec total_on?([tuple()], {:x, non_neg_integer()}) :: boolean()
  def total_on?(instrs, register) do
    tuple = List.to_tuple(instrs)
    labels = label_index(instrs)
    # The code starts after func_info; what precedes it is the failure exit.
    start = (Enum.find_index(instrs, &match?({:func_info, _, _, _}, &1)) || -1) + 1
    path = %{tracked: MapSet.new([register]), tested: false, passed: false}
    {found?, _seen} = walk_head(start, path, tuple, labels, MapSet.new())
    found?
  end

  defp label_index(instrs) do
    instrs
    |> Enum.with_index()
    |> Enum.reduce(%{}, fn
      {{:label, l}, idx}, acc -> Map.put(acc, l, idx)
      _, acc -> acc
    end)
  end

  # The path state: the registers holding the message or a projection of
  # it; whether the clause being walked has tested the message; and
  # whether some message test has PASSED on the way here. The last is
  # what a fail edge inherits — two clauses can share a tested prefix
  # (`{:DOWN, ref, _, _, _}` twice, the first with a `^ref` state match),
  # and the second is only as open as that prefix leaves it.
  defp walk_head(idx, path, tuple, labels, seen) do
    key = {idx, path.tested, path.passed, Enum.sort(path.tracked)}

    cond do
      idx >= tuple_size(tuple) -> {false, seen}
      MapSet.member?(seen, key) -> {false, seen}
      true -> head_step(elem(tuple, idx), idx, path, tuple, labels, MapSet.put(seen, key))
    end
  end

  defp goto_head(label, path, tuple, labels, seen) do
    case Map.fetch(labels, label) do
      {:ok, idx} -> walk_head(idx, path, tuple, labels, seen)
      :error -> {false, seen}
    end
  end

  # Both edges of a test. The pass edge falls through with what the
  # clause has established. The fail edge of a test on the message is
  # the next clause, as constrained as the passed prefix. The fail edge
  # of a test on the state is inside this clause once the message is
  # matched (a hoisted `case`, a `badmatch`, a map-access fallback);
  # before that it is the next clause when the target looks like one —
  # a clause begins with tests, a body fallback with a call.
  defp branch_head(idx, fail, on_message?, path, tuple, labels, seen) do
    pass_path = if on_message?, do: %{path | tested: true, passed: true}, else: path

    case walk_head(idx + 1, pass_path, tuple, labels, seen) do
      {true, seen} ->
        {true, seen}

      {false, seen} ->
        case fail_path(on_message?, path, fail, tuple, labels) do
          nil -> {false, seen}
          fail_path -> goto_head(fail, fail_path, tuple, labels, seen)
        end
    end
  end

  defp fail_path(true, path, _fail, _tuple, _labels), do: %{path | tested: path.passed}
  defp fail_path(false, %{tested: true} = path, _fail, _tuple, _labels), do: path

  defp fail_path(false, path, fail, tuple, labels) do
    if clause_start?(fail, tuple, labels), do: %{path | tested: path.passed}, else: nil
  end

  defp head_step({:test, _op, {:f, l}, args}, idx, path, tuple, labels, seen)
       when is_list(args) do
    on_message? = Enum.any?(args, &tracked?(&1, path.tracked))
    branch_head(idx, l, on_message?, path, tuple, labels, seen)
  end

  defp head_step({:test, _op, {:f, l}, src, _fields}, idx, path, tuple, labels, seen) do
    branch_head(idx, l, tracked?(src, path.tracked), path, tuple, labels, seen)
  end

  # A fail-labelled map read is a test on its subject; its destinations
  # hold map values, not the message.
  defp head_step({:get_map_elements, {:f, l}, src, {:list, kvs}}, idx, path, tuple, labels, seen) do
    on_message? = tracked?(src, path.tracked)
    tracked = kvs |> Enum.drop_every(2) |> Enum.reduce(path.tracked, &forget(&2, &1))
    branch_head(idx, l, on_message?, %{path | tracked: tracked}, tuple, labels, seen)
  end

  # Each arm is a clause group for that value; the default is the next
  # clause, as constrained as the passed prefix.
  defp head_step({op, src, {:f, fail}, {:list, pairs}}, _idx, path, tuple, labels, seen)
       when op in [:select_val, :select_tuple_arity] do
    on_message? = tracked?(src, path.tracked)
    arm_path = if on_message?, do: %{path | tested: true, passed: true}, else: path
    arms = pairs |> Enum.chunk_every(2) |> Enum.map(fn [_val, {:f, l}] -> {l, arm_path} end)

    default =
      case fail_path(on_message?, path, fail, tuple, labels) do
        nil -> []
        p -> [{fail, p}]
      end

    Enum.reduce_while(arms ++ default, {false, seen}, fn {l, p}, {_, seen} ->
      case goto_head(l, p, tuple, labels, seen) do
        {true, seen} -> {:halt, {true, seen}}
        {false, seen} -> {:cont, {false, seen}}
      end
    end)
  end

  defp head_step({:jump, {:f, l}}, _idx, path, tuple, labels, seen),
    do: goto_head(l, path, tuple, labels, seen)

  defp head_step({:move, src, dst}, idx, path, tuple, labels, seen),
    do: walk_head(idx + 1, %{path | tracked: track(path.tracked, src, dst)}, tuple, labels, seen)

  defp head_step({:swap, a, b}, idx, path, tuple, labels, seen) do
    tracked = path.tracked

    tracked =
      case {tracked?(a, tracked), tracked?(b, tracked)} do
        {true, false} -> tracked |> forget(a) |> MapSet.put(reg(b))
        {false, true} -> tracked |> forget(b) |> MapSet.put(reg(a))
        _ -> tracked
      end

    walk_head(idx + 1, %{path | tracked: tracked}, tuple, labels, seen)
  end

  defp head_step({:get_tuple_element, src, _i, dst}, idx, path, tuple, labels, seen),
    do: walk_head(idx + 1, %{path | tracked: track(path.tracked, src, dst)}, tuple, labels, seen)

  defp head_step({:get_hd, src, dst}, idx, path, tuple, labels, seen),
    do: walk_head(idx + 1, %{path | tracked: track(path.tracked, src, dst)}, tuple, labels, seen)

  defp head_step({:get_tl, src, dst}, idx, path, tuple, labels, seen),
    do: walk_head(idx + 1, %{path | tracked: track(path.tracked, src, dst)}, tuple, labels, seen)

  # The failure exit: not a clause.
  defp head_step({:func_info, _, _, _}, _idx, _path, _tuple, _labels, seen), do: {false, seen}

  # Bookkeeping the compiler emits between a head and its body.
  defp head_step({op, _}, idx, path, tuple, labels, seen)
       when op in [:label, :line, :init_yregs],
       do: walk_head(idx + 1, path, tuple, labels, seen)

  defp head_step({op, _, _}, idx, path, tuple, labels, seen)
       when op in [:allocate, :allocate_zero, :test_heap, :trim],
       do: walk_head(idx + 1, path, tuple, labels, seen)

  defp head_step({:allocate_heap, _, _, _}, idx, path, tuple, labels, seen),
    do: walk_head(idx + 1, path, tuple, labels, seen)

  # Anything else is the body: the clause is entered. Untested, it
  # accepts every message; tested, it is a real clause and the walk does
  # not continue into it.
  defp head_step(_instr, _idx, path, _tuple, _labels, seen), do: {not path.tested, seen}

  # Whether the block at `label` is a clause head: after bookkeeping and
  # register shuffling it tests something or is the failure exit. A body
  # fallback calls.
  defp clause_start?(label, tuple, labels) do
    case Map.fetch(labels, label) do
      :error -> false
      {:ok, idx} -> clause_start_at?(idx + 1, tuple)
    end
  end

  defp clause_start_at?(idx, tuple) when idx >= tuple_size(tuple), do: false

  defp clause_start_at?(idx, tuple) do
    case elem(tuple, idx) do
      {:test, _, _, _} ->
        true

      {:test, _, _, _, _} ->
        true

      {:select_val, _, _, _} ->
        true

      {:select_tuple_arity, _, _, _} ->
        true

      {:get_map_elements, {:f, _}, _, _} ->
        true

      {:func_info, _, _, _} ->
        true

      {:jump, _} ->
        true

      {op, _} when op in [:label, :line, :init_yregs] ->
        clause_start_at?(idx + 1, tuple)

      {op, _, _}
      when op in [:allocate, :allocate_zero, :test_heap, :trim, :move, :get_hd, :get_tl, :swap] ->
        clause_start_at?(idx + 1, tuple)

      {:allocate_heap, _, _, _} ->
        clause_start_at?(idx + 1, tuple)

      {:get_tuple_element, _, _, _} ->
        clause_start_at?(idx + 1, tuple)

      _ ->
        false
    end
  end

  defp forget(tracked, dst) do
    case reg(dst) do
      nil -> tracked
      r -> MapSet.delete(tracked, r)
    end
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
