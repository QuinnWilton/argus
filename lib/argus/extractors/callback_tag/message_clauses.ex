defmodule Argus.Extractors.CallbackTag.MessageClauses do
  @moduledoc """
  Questions about a callback's message clauses, and a receive's, that
  the tags a function compares cannot answer.

  - Which clauses take a message by its shape alone (`open_shapes/2`)?
    `handle_info(event, state) when is_atom(event)` takes every atom, and
    `handle_info({ref, result}, state) when is_reference(ref)` every
    2-tuple whose first element is a reference: neither compares the
    message to a literal, so `callback_tag` names nothing they take. A
    clause is open when some path through the heads reaches its body
    having tested the message (a type test, a tuple's arity, an element
    other than the tag) but never compared the message or its tag to a
    value. It is open to `:tuple`s when the path established the message
    is a tuple, and to `:any` message otherwise.
  - Does the catch-all do anything with the message (`catch_all_drops?/2`)?
    GenServer's own handle_info/2, and a `handle_info(_msg, state), do:
    {:noreply, state}`, drop it: a message no other clause takes goes
    nowhere. One that hands it to a helper, keeps it in the state, sends
    it on or tests it in a `case` may take it there. The walk goes
    forward from the catch-all's body carrying the registers the message,
    or anything made from it, is in; the message is dropped when it only
    ever reaches a reporter — Logger, `:logger`, IO, `inspect/2` and the
    string conversion an interpolation makes — and taken by anything
    else that reads it: another call, a return, a send, a test.
  - What shape does each tag a clause head compares take the message in
    (`tag_shapes/2`)? `handle_info(:tick, s)` takes the atom, arity 0;
    `handle_info({:tick, n}, s)` a 2-tuple tagged `:tick`. A timer armed
    with `{:tick, 1, :slow}` is a 3-tuple no clause takes, whatever its
    tag. The shape is what the path through the heads established: the
    tuple's arity (`test_arity`, `is_tagged_tuple`, a `select_tuple_arity`
    arm) when its tag was compared, 0 when the message itself was; -1 when
    a tag was compared on a tuple of no known arity.
  - Which monitors' `:DOWN` does some clause take whatever its reason
    (`takes_down/2`)? A monitor's `:DOWN` is `{:DOWN, ref, type, object,
    reason}`: the program chose the ref and the object when it took the
    monitor, the monitor's type (`:process`, `:port`) says which kind it
    was, and the runtime chooses the reason. A clause that pins the ref
    to the state, or compares a field of the state, takes the `:DOWN`s
    of the monitors the program keeps there; one that guards the reason
    (`when reason != :normal`) leaves the runtime's other reasons to no
    clause, and one that compares the type with `:process` takes no
    port monitor's. Clauses that split the reasons between them take
    every reason together: the path into a later clause is the earlier
    one's failed test, which touches nothing. `takes_exit?/2` asks the
    same of a trapped `{:EXIT, from, reason}`.
  - What shapes does a receive wait for (`receive_shapes/2`)? The same
    walk from a receive's `loop_rec`, whose failure exits are the next
    message and the wait: an atom, a tagged tuple, a tuple whose first
    element is compared with a value the function holds (a ref it made),
    a map, a tuple, or anything.

  The head walk is `Argus.Extractor.Dispatch.total_on?/2`'s, with more
  carried along the path: which tracked register is the message, which
  its tag (element 0) and which another part of it (and at which index),
  whether the path has compared the message or its tag to a value, and
  which elements of the message it has tested.
  """

  alias Argus.Extractor.Dispatch
  alias Argus.Instr
  import Argus.Instr, only: [slot: 1]

  # Modules a catch-all may hand the message to without taking it:
  # logging it and printing it. Kernel.inspect/2 is named on its own.
  @reporters [
    Logger,
    :logger,
    :error_logger,
    IO,
    Inspect,
    Inspect.Algebra,
    String.Chars,
    List.Chars,
    :io,
    :io_lib,
    :unicode
  ]

  @value_tests [:is_eq_exact, :is_ne_exact, :is_eq, :is_ne]
  @tuple_tests [:is_tuple, :test_arity, :is_tagged_tuple]

  @typep kind :: :msg | :tag | :part
  @typep path :: %{
           tracked: %{Instr.reg() => kind()},
           tested: boolean(),
           passed: boolean(),
           valued: boolean(),
           tuple: boolean(),
           map: boolean(),
           shape_tag: atom() | nil,
           arity: integer() | nil,
           parts: %{Instr.reg() => non_neg_integer()},
           touched: MapSet.t(non_neg_integer()),
           down_type: atom() | nil
         }

  @doc """
  The shapes some clause takes the message in `register` by, untested
  for its value: `:any` (an atom, or anything a type test lets through)
  and `:tuple`. A catch-all's body is not an open clause.
  """
  @spec open_shapes([tuple()], Instr.reg()) :: [:any | :tuple]
  def open_shapes(instrs, register) do
    instrs
    |> open_clauses(register)
    |> Enum.map(&elem(&1, 0))
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc """
  `open_shapes/2` with the tuple's arity where the path through the
  heads tested it: `{:tuple, 2}` for `{ref, result} when
  is_reference(ref)`, `{:tuple, -1}` for `msg when is_tuple(msg)`, and
  `{:any, -1}`.
  """
  @spec open_clauses([tuple()], Instr.reg()) :: [{:any | :tuple, integer()}]
  def open_clauses(instrs, register) do
    entries = entries(instrs, register)
    catch_all = for {idx, %{tested: false}} <- entries, into: MapSet.new(), do: idx

    entries
    |> Enum.flat_map(fn
      {idx, %{tested: true, valued: false, tuple: tuple?, arity: arity}} ->
        if MapSet.member?(catch_all, idx),
          do: [],
          else: [{if(tuple?, do: :tuple, else: :any), if(tuple?, do: arity || -1, else: -1)}]

      _entry ->
        []
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc """
  The `{tag, arity}` shapes the clause heads take the message in
  `register` by: arity 0 for the atom itself, N for an N-tuple whose
  element 0 is the tag, -1 for a tuple of no known arity. A clause whose
  head compares no tag has none.
  """
  @spec tag_shapes([tuple()], Instr.reg()) :: [{atom(), integer()}]
  def tag_shapes(instrs, register) do
    for(
      {_idx, %{shape_tag: tag, arity: arity}} when tag != nil <- entries(instrs, register),
      do: {tag, arity || -1}
    )
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc """
  The monitor types some clause takes every `:DOWN` of, whatever its
  reason: `:process` when the head compares the type with `:process`,
  `:any` when it leaves the type alone, or the atom it compares. A head
  that tests the reason (a literal, a guard, a pattern) takes some of
  the runtime's reasons, and is left out; one that pins the ref or the
  object, or asks the state, is not.
  """
  @spec takes_down([tuple()], Instr.reg()) :: [atom()]
  def takes_down(instrs, register) do
    for(
      {_idx, %{shape_tag: :DOWN, arity: 5, touched: touched, down_type: type}} <-
        entries(instrs, register),
      not MapSet.member?(touched, 4),
      not MapSet.member?(touched, 2),
      do: type || :any
    )
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc """
  Whether some clause takes every `{:EXIT, from, reason}`, whatever the
  reason: the linked process chose the reason, the program chose `from`
  and the state. A clause for `:normal` alone, or one guarding the
  reason, takes some exits and not a crash's.
  """
  @spec takes_exit?([tuple()], Instr.reg()) :: boolean()
  def takes_exit?(instrs, register) do
    Enum.any?(entries(instrs, register), fn
      {_idx, %{shape_tag: :EXIT, arity: 3, touched: touched}} -> not MapSet.member?(touched, 2)
      _entry -> false
    end)
  end

  @doc """
  The shapes the clauses of the receive whose `loop_rec` is at `idx`
  take the message in: the atom (`:tick`), a tuple with that tag
  (`{:tick, …}`), a tuple whose first element is compared with a value
  the function holds — a ref it made, a pid — (`{ref, …}`), a map, a
  tuple of any tag (`tuple`), or anything (`any`: a variable, a guard
  that is no shape).
  """
  @spec receive_shapes([tuple()], non_neg_integer()) :: [String.t()]
  def receive_shapes(instrs, idx) do
    {:loop_rec, _fail, register} = Enum.at(instrs, idx)

    instrs
    |> entries_from(idx + 1, register)
    |> Enum.map(fn {_body, path} -> receive_shape(path) end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp receive_shape(%{shape_tag: tag, arity: 0}) when tag != nil, do: inspect(tag)
  defp receive_shape(%{shape_tag: tag}) when tag != nil, do: "{#{inspect(tag)}, …}"
  defp receive_shape(%{tuple: true, valued: true}), do: "{ref, …}"
  defp receive_shape(%{map: true}), do: "map"
  defp receive_shape(%{tuple: true}), do: "tuple"
  defp receive_shape(_path), do: "any"

  @doc """
  Whether the function has a catch-all for the message in `register`
  that does nothing with it but report it. False without a catch-all.
  """
  @spec catch_all_drops?([tuple()], Instr.reg()) :: boolean()
  def catch_all_drops?(instrs, register) do
    tuple = List.to_tuple(instrs)
    labels = Instr.labels(instrs)

    case for({idx, %{tested: false} = path} <- entries(instrs, register), do: {idx, path}) do
      [] ->
        false

      catch_alls ->
        Enum.all?(catch_alls, fn {idx, path} ->
          holding = path.tracked |> Map.keys() |> Enum.sort()
          drops?(:queue.from_list([{idx, holding}]), %{}, tuple, labels)
        end)
    end
  end

  # ── The heads ─────────────────────────────────────────────────────

  # Every body a path through the clause heads enters, with the path.
  @spec entries([tuple()], Instr.reg()) :: [{non_neg_integer(), path()}]
  defp entries(instrs, register) do
    start = (Enum.find_index(instrs, &match?({:func_info, _, _, _}, &1)) || -1) + 1
    entries_from(instrs, start, register)
  end

  defp entries_from(instrs, start, register) do
    tuple = List.to_tuple(instrs)
    labels = Instr.labels(instrs)

    path = %{
      tracked: %{Instr.register(register) => :msg},
      tested: false,
      passed: false,
      valued: false,
      tuple: false,
      map: false,
      shape_tag: nil,
      arity: nil,
      parts: %{},
      touched: MapSet.new(),
      down_type: nil
    }

    {acc, _seen} = walk(start, path, tuple, labels, {[], MapSet.new()})
    Enum.uniq(acc)
  end

  defp walk(idx, path, tuple, labels, {acc, seen} = st) do
    key = {idx, path}

    cond do
      idx >= tuple_size(tuple) -> st
      MapSet.member?(seen, key) -> st
      true -> step(elem(tuple, idx), idx, path, tuple, labels, {acc, MapSet.put(seen, key)})
    end
  end

  defp goto(label, path, tuple, labels, st) do
    case Map.fetch(labels, label) do
      {:ok, idx} -> walk(idx, path, tuple, labels, st)
      :error -> st
    end
  end

  defp step({:test, op, {:f, l}, args}, idx, path, tuple, labels, st) when is_list(args) do
    kinds = for a <- args, k = Map.get(path.tracked, slot(a)), do: k

    valued? =
      (op in @value_tests and Enum.any?(kinds, &(&1 in [:msg, :tag]))) or
        (op == :is_tagged_tuple and :msg in kinds)

    shaped? = op in @tuple_tests and :msg in kinds
    {pass, fail} = shapes(op, args, path)
    pass = touch(pass, op, args, path)
    pass = if op == :is_map and :msg in kinds, do: %{pass | map: true}, else: pass

    branch(idx, l, {kinds != [], valued?, shaped?}, pass, fail, tuple, labels, st)
  end

  defp step({:test, _op, {:f, l}, src, _fields}, idx, path, tuple, labels, st) do
    pass = touch_part(path, src)
    branch(idx, l, {tracked?(path, src), false, false}, pass, path, tuple, labels, st)
  end

  # A fail-labelled map read is a test on its subject; its destinations
  # hold map values, not the message.
  defp step({:get_map_elements, {:f, l}, src, {:list, kvs}}, idx, path, tuple, labels, st) do
    on_message? = tracked?(path, src)
    tracked = kvs |> Enum.drop_every(2) |> Enum.reduce(path.tracked, &Map.delete(&2, slot(&1)))
    path = %{path | tracked: tracked}
    branch(idx, l, {on_message?, false, false}, path, path, tuple, labels, st)
  end

  defp step({op, src, {:f, fail}, {:list, pairs}}, _idx, path, tuple, labels, st)
       when op in [:select_val, :select_tuple_arity] do
    kind = Map.get(path.tracked, slot(src))

    arm_path =
      if kind == nil,
        do: path,
        else:
          %{
            path
            | tested: true,
              passed: true,
              valued: path.valued or (op == :select_val and kind in [:msg, :tag]),
              tuple: path.tuple or (op == :select_tuple_arity and kind == :msg)
          }
          |> touch_part(src)

    arms =
      pairs
      |> Enum.chunk_every(2)
      |> Enum.map(fn [value, {:f, l}] -> {l, arm_shape(op, kind, value, arm_path)} end)

    default =
      case fail_path(kind != nil, path, fail, tuple, labels) do
        nil -> []
        p -> [{fail, default_shape(op, kind, p)}]
      end

    Enum.reduce(arms ++ default, st, fn {l, p}, st -> goto(l, p, tuple, labels, st) end)
  end

  defp step({:jump, {:f, l}}, _idx, path, tuple, labels, st), do: goto(l, path, tuple, labels, st)

  defp step({:move, src, dst}, idx, path, tuple, labels, st),
    do: walk(idx + 1, %{path | tracked: track(path.tracked, src, dst, nil)}, tuple, labels, st)

  defp step({:swap, a, b}, idx, path, tuple, labels, st) do
    ka = Map.get(path.tracked, slot(a))
    kb = Map.get(path.tracked, slot(b))
    tracked = path.tracked |> Map.delete(slot(a)) |> Map.delete(slot(b))
    tracked = if ka, do: Map.put(tracked, slot(b), ka), else: tracked
    tracked = if kb, do: Map.put(tracked, slot(a), kb), else: tracked
    walk(idx + 1, %{path | tracked: tracked}, tuple, labels, st)
  end

  defp step({:get_tuple_element, src, i, dst}, idx, path, tuple, labels, st) do
    kind = if Map.get(path.tracked, slot(src)) == :msg and i == 0, do: :tag, else: :part

    parts =
      if Map.get(path.tracked, slot(src)) == :msg,
        do: Map.put(path.parts, slot(dst), i),
        else: Map.delete(path.parts, slot(dst))

    path = %{path | tracked: track(path.tracked, src, dst, kind), parts: parts}
    walk(idx + 1, path, tuple, labels, st)
  end

  # A guard's element/2 of the message reads a part of it, as
  # get_tuple_element does: `element(1, msg) =:= :trace_ts` compares its
  # tag (vmq_tracer's trace clause). Another BIF is where the head ends.
  defp step({:bif, :element, {:f, _}, [{:integer, i}, src], dst}, idx, path, tuple, labels, st)
       when is_integer(i) and i >= 1 do
    if Map.get(path.tracked, slot(src)) == :msg and slot(dst) != nil do
      path = %{
        path
        | tracked: Map.put(path.tracked, slot(dst), if(i == 1, do: :tag, else: :part)),
          parts: Map.put(path.parts, slot(dst), i - 1)
      }

      walk(idx + 1, path, tuple, labels, st)
    else
      {acc, seen} = st
      {[{idx, path} | acc], seen}
    end
  end

  defp step({op, src, dst}, idx, path, tuple, labels, st) when op in [:get_hd, :get_tl],
    do: walk(idx + 1, %{path | tracked: track(path.tracked, src, dst, :part)}, tuple, labels, st)

  # The failure exit: not a clause. A receive's is the next message
  # (loop_rec_end) or the wait for one.
  defp step({:func_info, _, _, _}, _idx, _path, _tuple, _labels, st), do: st
  defp step({:loop_rec_end, _}, _idx, _path, _tuple, _labels, st), do: st
  defp step({:wait, _}, _idx, _path, _tuple, _labels, st), do: st
  defp step({:wait_timeout, _, _}, _idx, _path, _tuple, _labels, st), do: st
  defp step(:timeout, _idx, _path, _tuple, _labels, st), do: st

  # Bookkeeping the compiler emits between a head and its body.
  defp step({op, _}, idx, path, tuple, labels, st) when op in [:label, :line, :init_yregs],
    do: walk(idx + 1, path, tuple, labels, st)

  defp step({op, _, _}, idx, path, tuple, labels, st)
       when op in [:allocate, :allocate_zero, :test_heap, :trim],
       do: walk(idx + 1, path, tuple, labels, st)

  defp step({:allocate_heap, _, _, _}, idx, path, tuple, labels, st),
    do: walk(idx + 1, path, tuple, labels, st)

  # The body: the path that entered it is recorded.
  defp step(_instr, idx, path, _tuple, _labels, {acc, seen}), do: {[{idx, path} | acc], seen}

  # The message elements a passed test asked something of. A `:DOWN`'s
  # third element compared with an atom names the monitor type the
  # clause takes (`down_type`) rather than a subset of one monitor's.
  defp touch(pass, op, [a, b], %{shape_tag: :DOWN, arity: 5} = path)
       when op in [:is_eq_exact, :is_eq] do
    case Enum.find([{a, b}, {b, a}], fn {part, _} -> element(path, part) == {:ok, 2} end) do
      {_part, {:atom, type}} -> %{pass | down_type: type}
      _ -> Enum.reduce([a, b], pass, &touch_part(&2, &1))
    end
  end

  defp touch(pass, _op, args, _path), do: Enum.reduce(args, pass, &touch_part(&2, &1))

  defp touch_part(path, operand) do
    case element(path, operand) do
      {:ok, i} -> %{path | touched: MapSet.put(path.touched, i)}
      :error -> path
    end
  end

  # The message element a register holds: `parts` keeps the index a
  # get_tuple_element read it from, and `tracked` whether the register
  # still holds it (a later write, a struct's module read into it, drops
  # it from `tracked` alone).
  defp element(path, operand) do
    with :part <- Map.get(path.tracked, slot(operand)),
         {:ok, i} <- Map.fetch(path.parts, slot(operand)) do
      {:ok, i}
    else
      _ -> :error
    end
  end

  # `path` goes on where the test passes, `failed` (the same path with
  # the shape a failure establishes) where it fails.
  defp branch(idx, fail, {on_message?, valued?, shaped?}, path, failed, tuple, labels, st) do
    pass_path =
      if on_message?,
        do: %{
          path
          | tested: true,
            passed: true,
            valued: path.valued or valued?,
            tuple: path.tuple or shaped?
        },
        else: path

    st = walk(idx + 1, pass_path, tuple, labels, st)

    case fail_path(on_message?, failed, fail, tuple, labels) do
      nil -> st
      p -> goto(fail, p, tuple, labels, st)
    end
  end

  # The shape each side of a test establishes: `{pass, fail}` paths. A
  # comparison of the message with an atom takes the atom (arity 0); of
  # its tag, a tuple so tagged; an arity test, a tuple of that arity. A
  # failed comparison leaves the arity the path had; a failed arity test
  # leaves none. `is_ne_exact` fails where the two are equal.
  defp shapes(op, [a, b], path) when op in [:is_eq_exact, :is_eq, :is_ne_exact, :is_ne] do
    equal =
      case {Map.get(path.tracked, slot(a)), b, Map.get(path.tracked, slot(b)), a} do
        {:msg, value, _, _} -> literal_shape(value, path)
        {_, _, :msg, value} -> literal_shape(value, path)
        {:tag, {:atom, x}, _, _} -> %{path | shape_tag: x}
        {_, _, :tag, {:atom, x}} -> %{path | shape_tag: x}
        _ -> path
      end

    unequal = if equal == path, do: path, else: %{path | shape_tag: nil}

    if op in [:is_eq_exact, :is_eq], do: {equal, unequal}, else: {unequal, equal}
  end

  defp shapes(:is_tagged_tuple, [src, n, {:atom, x}], path) when is_integer(n) do
    if Map.get(path.tracked, slot(src)) == :msg,
      do: {%{path | shape_tag: x, arity: n}, %{path | shape_tag: nil, arity: nil}},
      else: {path, path}
  end

  defp shapes(:test_arity, [src, n], path) when is_integer(n) do
    if Map.get(path.tracked, slot(src)) == :msg,
      do: {%{path | arity: n}, %{path | shape_tag: nil, arity: nil}},
      else: {path, path}
  end

  defp shapes(_op, _args, path), do: {path, path}

  defp arm_shape(:select_tuple_arity, :msg, n, path) when is_integer(n), do: %{path | arity: n}
  defp arm_shape(:select_val, :msg, {:atom, x}, path), do: %{path | shape_tag: x, arity: 0}
  defp arm_shape(:select_val, :tag, {:atom, x}, path), do: %{path | shape_tag: x}
  defp arm_shape(_op, _kind, _value, path), do: path

  defp default_shape(:select_tuple_arity, :msg, path), do: %{path | shape_tag: nil, arity: nil}

  defp default_shape(:select_val, kind, path) when kind in [:msg, :tag],
    do: %{path | shape_tag: nil}

  defp default_shape(_op, _kind, path), do: path

  # The message compared whole with a literal: an atom, or a tuple with
  # an atom first (`handle_info({:tick, :fast}, s)` compiles to one
  # comparison with the literal tuple).
  defp literal_shape({:atom, x}, path), do: %{path | shape_tag: x, arity: 0}

  defp literal_shape({:literal, t}, path)
       when is_tuple(t) and tuple_size(t) > 0 and is_atom(elem(t, 0)),
       do: %{path | shape_tag: elem(t, 0), arity: tuple_size(t)}

  defp literal_shape(_value, path), do: path

  # As in Dispatch: a failed test on the message is the next clause, as
  # constrained as the prefix that passed; a failed test on the state
  # before the message is matched is the next clause when the target
  # looks like one.
  defp fail_path(true, path, _fail, _tuple, _labels), do: next_clause(path)
  defp fail_path(false, %{tested: true} = path, _fail, _tuple, _labels), do: path

  defp fail_path(false, path, fail, tuple, labels) do
    if Dispatch.clause_start?(fail, tuple, labels), do: next_clause(path), else: nil
  end

  defp next_clause(path) do
    %{
      path
      | tested: path.passed,
        valued: path.passed and path.valued,
        tuple: path.passed and path.tuple
    }
  end

  defp track(tracked, src, dst, kind) do
    case {slot(src), slot(dst)} do
      {nil, _} ->
        tracked

      {_, nil} ->
        tracked

      {s, d} ->
        case Map.fetch(tracked, s) do
          {:ok, k} -> Map.put(tracked, d, kind || k)
          :error -> Map.delete(tracked, d)
        end
    end
  end

  defp tracked?(path, operand), do: Map.has_key?(path.tracked, slot(operand))

  # ── The catch-all's body ──────────────────────────────────────────

  # The registers holding the message travel as a sorted list, and the
  # work items seen are a map's keys: an item is a key.
  defp drops?(queue, seen, tuple, labels) do
    case :queue.out(queue) do
      {:empty, _} ->
        true

      {{:value, {idx, _holding} = item}, rest} ->
        if idx >= tuple_size(tuple) or Map.has_key?(seen, item) do
          drops?(rest, seen, tuple, labels)
        else
          visit(elem(tuple, idx), item, rest, Map.put(seen, item, true), tuple, labels)
        end
    end
  end

  defp visit(instr, {idx, holding}, queue, seen, tuple, labels) do
    used? = Enum.any?(Instr.uses(instr), &(&1 in holding))
    carried = Instr.carry(instr, holding)

    case consume(instr, used?) do
      :takes ->
        false

      :reports ->
        drops?(successors(instr, idx, carried, queue, labels), seen, tuple, labels)

      :flows ->
        held = if used?, do: carried ++ Instr.defs(instr), else: carried
        drops?(successors(instr, idx, held, queue, labels), seen, tuple, labels)
    end
  end

  defp successors(instr, idx, holding, queue, labels) do
    holding = holding |> Enum.uniq() |> Enum.sort()
    targets = for l <- Instr.targets(instr), {:ok, i} <- [Map.fetch(labels, l)], do: i
    next = if Instr.falls_through?(instr), do: [idx + 1], else: []
    Enum.reduce(targets ++ next, queue, &:queue.in({&1, holding}, &2))
  end

  # What an instruction that reads the message does with it: hands it to
  # a reporter, takes it somewhere, or makes something new of it (a
  # tuple, a string, a closure) that the walk goes on carrying.
  defp consume(_instr, false), do: :flows

  defp consume(instr, true) do
    case remote(instr) do
      {:ok, mod, fun} ->
        if reporter?(mod, fun), do: :reports, else: :takes

      :no ->
        if takes?(instr), do: :takes, else: :flows
    end
  end

  defp takes?(:send), do: true
  defp takes?({:test, _, _, _}), do: true
  defp takes?({:test, _, _, _, _}), do: true
  defp takes?({op, _, _, _}) when op in [:select_val, :select_tuple_arity], do: true
  defp takes?(instr), do: Instr.call?(instr) or Instr.tail_call?(instr) or Instr.exits?(instr)

  defp reporter?(Kernel, :inspect), do: true
  defp reporter?(mod, _fun), do: mod in @reporters

  defp remote({op, _, {:extfunc, m, f, _a}}) when op in [:call_ext, :call_ext_only],
    do: {:ok, m, f}

  defp remote({:call_ext_last, _, {:extfunc, m, f, _a}, _}), do: {:ok, m, f}
  defp remote(_instr), do: :no
end
