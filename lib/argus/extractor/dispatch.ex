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

  alias Argus.Instr

  @doc """
  The label of the function's `func_info` instruction, or `nil`: the
  label before it, past the line marker between them. OTP 29's
  `beam_disasm` lays a function out `label, line, func_info`, as the
  compiler does; OTP 28's does that for a module's first function only,
  and `line, label, func_info` for the rest.
  """
  @spec func_info_label([tuple()]) :: non_neg_integer() | nil
  def func_info_label(instrs) do
    {prefix, rest} = Enum.split_while(instrs, &(not match?({:func_info, _, _, _}, &1)))

    if rest == [] do
      nil
    else
      prefix
      |> Enum.reverse()
      |> Enum.drop_while(&match?({:line, _}, &1))
      |> case do
        [{:label, l} | _] -> l
        _ -> nil
      end
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

  # A literal's value is data: the literal `{:f, 3}` branches nowhere.
  defp collect_f({:literal, _value}, acc), do: acc

  defp collect_f(term, acc) when is_tuple(term),
    do: term |> Tuple.to_list() |> collect_f(acc)

  # Cell by cell, so an improper tail is asked like any element.
  defp collect_f([], acc), do: acc
  defp collect_f([head | tail], acc), do: collect_f(tail, collect_f(head, acc))
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

  @doc """
  Whether the block at `label` is a clause head: after bookkeeping and
  register shuffling it tests something or is the failure exit. A body
  fallback calls. `tuple` is the function's instructions as a tuple,
  `labels` its label index (`labels/1`).
  """
  @spec clause_start?(non_neg_integer(), tuple(), %{non_neg_integer() => non_neg_integer()}) ::
          boolean()
  def clause_start?(label, tuple, labels) do
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

  @doc """
  The tags each instruction can run under, of the argument in
  `register` (a callback's request, a dispatcher's first argument): for
  every instruction index reached from the entry, the atoms the argument
  was established to be (a bare atom, or the first element of a tuple) on
  some path to it, plus `:any` when some path reaches it without having
  established one.

  `handle_call({:answer, n}, _, s)` and `handle_call({:echo, n}, _, s)`
  compile into one function that tests the request's tag and branches to
  a body per clause; an instruction in the `:answer` body is reached only
  along paths where the tag test for `:answer` passed, so it runs under
  `[":answer"]`. A catch-all clause, or a body that dispatches through a
  helper, is reached with no tag established and runs under `:any`.
  `route(:local, n)` and `route(:remote, n)` are the same shape.

  Every path is walked — both edges of each test, every select arm, the
  handlers of a `try` — carrying the registers that hold the argument and
  its tag (`Argus.Instr.carry/2` between the tests this reads itself), so
  a nested `case` on the argument in the body refines the tag just as a
  clause head does, and a tag is never attributed along a path where the
  register compared no longer holds the argument. A test on an
  established tag prunes the edge it contradicts. Sound for the question
  it answers: the tags listed are every tag some path can carry there.
  """
  @spec argument_tags([tuple()], {:x, non_neg_integer()}) :: %{
          non_neg_integer() => MapSet.t(String.t() | :any)
        }
  def argument_tags(instrs, register) do
    tuple = List.to_tuple(instrs)
    labels = labels(instrs)
    start = %{idx: entry_index(instrs), msg: [register], tag_regs: [], tag: nil}
    # `seen` is a map, not a MapSet: dialyzer loses the MapSet's opacity
    # through the recursion.
    walk_tags([start], tuple, labels, %{}, %{})
  end

  defp walk_tags([], _tuple, _labels, _seen, acc), do: acc

  defp walk_tags([state | rest], tuple, labels, seen, acc) do
    key = {state.idx, state.msg, state.tag_regs, state.tag}

    if state.idx >= tuple_size(tuple) or Map.has_key?(seen, key) do
      walk_tags(rest, tuple, labels, seen, acc)
    else
      tag = state.tag || :any
      acc = Map.update(acc, state.idx, MapSet.new([tag]), &MapSet.put(&1, tag))
      next = tag_step(elem(tuple, state.idx), state, labels)
      walk_tags(next ++ rest, tuple, labels, Map.put(seen, key, true), acc)
    end
  end

  # The successor states of the instruction at state.idx.
  defp tag_step({:test, op, {:f, fail}, [a, b]} = instr, state, labels)
       when op in [:is_eq_exact, :is_ne_exact] do
    case compared_tag(state, a, b) do
      nil ->
        generic_tag_step(instr, state, labels)

      atom ->
        equal = narrow(state, atom)
        other = if state.tag == atom, do: nil, else: advance(state, instr)

        {on_pass, on_fail} = if op == :is_eq_exact, do: {equal, other}, else: {other, equal}

        List.wrap(on_pass && %{on_pass | idx: state.idx + 1}) ++
          List.wrap(on_fail && goto(on_fail, fail, labels))
    end
  end

  defp tag_step(
         {:test, :is_tagged_tuple, {:f, fail}, [src, _arity, {:atom, atom}]} = instr,
         state,
         labels
       )
       when is_atom(atom) do
    if held?(src, state.msg) do
      pass = narrow(state, inspect(atom))

      List.wrap(pass && %{pass | idx: state.idx + 1}) ++
        List.wrap(goto(advance(state, instr), fail, labels))
    else
      generic_tag_step(instr, state, labels)
    end
  end

  defp tag_step({:select_val, src, {:f, fail}, {:list, pairs}} = instr, state, labels) do
    if held?(src, state.msg) or held?(src, state.tag_regs) do
      arms =
        pairs
        |> Enum.chunk_every(2)
        |> Enum.flat_map(fn
          [{:atom, atom}, {:f, l}] when is_atom(atom) ->
            List.wrap(goto(narrow(state, inspect(atom)), l, labels))

          [_value, {:f, l}] ->
            List.wrap(goto(advance(state, instr), l, labels))

          _malformed ->
            []
        end)

      arms ++ List.wrap(goto(advance(state, instr), fail, labels))
    else
      generic_tag_step(instr, state, labels)
    end
  end

  defp tag_step({:get_tuple_element, src, 0, dst} = instr, state, _labels) do
    next = advance(state, instr)

    if held?(src, state.msg),
      do: [
        %{next | idx: state.idx + 1, tag_regs: Enum.sort(Enum.uniq([reg(dst) | next.tag_regs]))}
      ],
      else: [%{next | idx: state.idx + 1}]
  end

  defp tag_step(instr, state, labels), do: generic_tag_step(instr, state, labels)

  defp generic_tag_step(instr, state, labels) do
    next = advance(state, instr)
    fall = if Instr.falls_through?(instr), do: [%{next | idx: state.idx + 1}], else: []
    fall ++ Enum.flat_map(Instr.targets(instr), &List.wrap(goto(next, &1, labels)))
  end

  @doc """
  The instruction indices reached from the entry when the argument in
  `register` is the atom `value`: a test on the argument (or a copy of
  it) takes only the edge that value takes, and every other instruction
  both. `terminate(:shutdown, s)` followed by `terminate(reason, s)`
  compiles into one function whose second body is reached only when the
  reason is not `:shutdown`; with `value` `:shutdown`, its instructions
  are not in the set.

  An atom fails every type test but `is_atom` (and passes the tests a
  term of any type passes), equals only itself, and is no tuple, so
  `select_tuple_arity` takes its fail label. A test this does not read
  takes both edges, which keeps the set a superset of what runs.

  With `avoid`, instruction indices, the walk does not step onto them:
  what is reached without passing any. An instruction reached with the
  value but not without `avoid` is on every path the value takes to it
  through one of them.
  """
  @spec reached_with(
          [tuple()],
          {:x, non_neg_integer()},
          atom(),
          [non_neg_integer()]
        ) :: MapSet.t(non_neg_integer())
  def reached_with(instrs, register, value, avoid \\ []) when is_atom(value) do
    tuple = List.to_tuple(instrs)
    labels = labels(instrs)

    # `seen` and `reached` are maps, not MapSets, for the reason
    # argument_tags/2's `seen` is: dialyzer loses the opacity through the
    # recursion. The avoided indices are seen from the start.
    seen = Map.new(avoid, &{&1, true})

    [{entry_index(instrs), [register]}]
    |> walk_fixed(tuple, labels, value, seen, %{})
    |> Map.keys()
    |> MapSet.new()
  end

  @doc """
  `reached_with/3`, with where the value is at each instruction reached:
  the registers that hold it (the argument in `register`, or a copy) on
  every path the walk takes there with it, before the instruction runs.
  At a call, an argument register in the list hands the value on to the
  callee in that position whichever way the call was reached; one that
  holds it on some paths only is left out.
  """
  @spec reached_holding([tuple()], {:x, non_neg_integer()}, atom()) :: %{
          non_neg_integer() => [{:x | :y, non_neg_integer()}]
        }
  def reached_holding(instrs, register, value) when is_atom(value) do
    walk_fixed(
      [{entry_index(instrs), [register]}],
      List.to_tuple(instrs),
      labels(instrs),
      value,
      %{},
      %{}
    )
  end

  defp walk_fixed([], _tuple, _labels, _value, _seen, reached), do: reached

  defp walk_fixed([{idx, held} = state | rest], tuple, labels, value, seen, reached) do
    if idx >= tuple_size(tuple) or Map.has_key?(seen, state) or Map.has_key?(seen, idx) do
      walk_fixed(rest, tuple, labels, value, seen, reached)
    else
      next = fixed_step(elem(tuple, idx), idx, held, labels, value)

      walk_fixed(
        next ++ rest,
        tuple,
        labels,
        value,
        Map.put(seen, state, true),
        Map.update(reached, idx, held, fn before -> Enum.filter(before, &(&1 in held)) end)
      )
    end
  end

  defp fixed_step({:test, op, {:f, fail}, [a, b]} = instr, idx, held, labels, value)
       when op in [:is_eq_exact, :is_ne_exact, :is_eq, :is_ne] do
    other =
      cond do
        held?(a, held) -> {:ok, b}
        held?(b, held) -> {:ok, a}
        true -> :none
      end

    case other do
      {:ok, operand} ->
        case literal_equal?(operand, value) do
          :unknown ->
            generic_fixed_step(instr, idx, held, labels)

          equal? ->
            passes? = if op in [:is_eq_exact, :is_eq], do: equal?, else: not equal?
            held = Enum.sort(Instr.carry(instr, held))
            if passes?, do: [{idx + 1, held}], else: fixed_goto(fail, held, labels)
        end

      :none ->
        generic_fixed_step(instr, idx, held, labels)
    end
  end

  defp fixed_step({:test, op, {:f, fail}, [src | _]} = instr, idx, held, labels, _value)
       when op in [
              :is_atom,
              :is_tuple,
              :is_tagged_tuple,
              :test_arity,
              :is_list,
              :is_nonempty_list,
              :is_nil,
              :is_map,
              :is_binary,
              :is_bitstr,
              :is_integer,
              :is_float,
              :is_number,
              :is_pid,
              :is_port,
              :is_reference,
              :is_function,
              :is_function2
            ] do
    if held?(src, held) do
      held = Enum.sort(Instr.carry(instr, held))
      if op == :is_atom, do: [{idx + 1, held}], else: fixed_goto(fail, held, labels)
    else
      generic_fixed_step(instr, idx, held, labels)
    end
  end

  defp fixed_step(
         {:select_val, src, {:f, fail}, {:list, pairs}} = instr,
         idx,
         held,
         labels,
         value
       ) do
    if held?(src, held) do
      held = Enum.sort(Instr.carry(instr, held))

      pairs
      |> Enum.chunk_every(2)
      |> Enum.find_value(fixed_goto(fail, held, labels), fn
        [operand, {:f, l}] ->
          if literal_equal?(operand, value) == true, do: fixed_goto(l, held, labels)

        _malformed ->
          nil
      end)
    else
      generic_fixed_step(instr, idx, held, labels)
    end
  end

  defp fixed_step(
         {:select_tuple_arity, src, {:f, fail}, _arms} = instr,
         idx,
         held,
         labels,
         _value
       ) do
    if held?(src, held),
      do: fixed_goto(fail, Enum.sort(Instr.carry(instr, held)), labels),
      else: generic_fixed_step(instr, idx, held, labels)
  end

  defp fixed_step(instr, idx, held, labels, _value),
    do: generic_fixed_step(instr, idx, held, labels)

  defp generic_fixed_step(instr, idx, held, labels) do
    held = Enum.sort(Instr.carry(instr, held))
    fall = if Instr.falls_through?(instr), do: [{idx + 1, held}], else: []
    fall ++ Enum.flat_map(Instr.targets(instr), &fixed_goto(&1, held, labels))
  end

  defp fixed_goto(label, held, labels) do
    case Map.fetch(labels, label) do
      {:ok, idx} -> [{idx, held}]
      :error -> []
    end
  end

  # Whether a literal operand equals the atom `value`: an atom compares
  # by identity, and every other literal kind differs from any atom
  # (`nil` is the empty list). A register is not known.
  defp literal_equal?({:atom, a}, value), do: a == value
  defp literal_equal?({:literal, term}, value), do: term === value
  defp literal_equal?(nil, _value), do: false

  defp literal_equal?({kind, _}, _value)
       when kind in [:integer, :float, :char, :string, :binary],
       do: false

  defp literal_equal?(_operand, _value), do: :unknown

  # The atom a test compares a request (or its tag) register against.
  defp compared_tag(state, a, b) do
    cond do
      held?(a, state.msg) or held?(a, state.tag_regs) -> atom_operand(b)
      held?(b, state.msg) or held?(b, state.tag_regs) -> atom_operand(a)
      true -> nil
    end
  end

  defp atom_operand({:atom, atom}) when is_atom(atom), do: inspect(atom)
  defp atom_operand(_operand), do: nil

  # The state once the tag is `atom`, or nil when the path already
  # established another: that edge cannot be taken.
  defp narrow(%{tag: nil} = state, atom), do: %{state | tag: atom}
  defp narrow(%{tag: atom} = state, atom), do: state
  defp narrow(_state, _atom), do: nil

  # The registers holding the request and its tag after `instr`.
  defp advance(state, instr) do
    %{
      state
      | msg: instr |> Instr.carry(state.msg) |> Enum.sort(),
        tag_regs: instr |> Instr.carry(state.tag_regs) |> Enum.sort()
    }
  end

  defp goto(nil, _label, _labels), do: nil

  defp goto(state, label, labels) do
    case Map.fetch(labels, label) do
      {:ok, idx} -> %{state | idx: idx}
      :error -> nil
    end
  end

  defp held?(operand, regs), do: reg(operand) in regs

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
