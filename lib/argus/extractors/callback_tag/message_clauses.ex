defmodule Argus.Extractors.CallbackTag.MessageClauses do
  @moduledoc """
  Two questions about a callback's message clauses that the tags it
  compares cannot answer.

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

  The head walk is `Argus.Extractor.Dispatch.total_on?/2`'s, with more
  carried along the path: which tracked register is the message, which
  its tag (element 0) and which another part of it, and whether the path
  has compared the message or its tag to a value.
  """

  alias Argus.Extractor.Dispatch
  alias Argus.Instr

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
           tuple: boolean()
         }

  @doc """
  The shapes some clause takes the message in `register` by, untested
  for its value: `:any` (an atom, or anything a type test lets through)
  and `:tuple`. A catch-all's body is not an open clause.
  """
  @spec open_shapes([tuple()], Instr.reg()) :: [:any | :tuple]
  def open_shapes(instrs, register) do
    entries = entries(instrs, register)
    catch_all = for {idx, %{tested: false}} <- entries, into: MapSet.new(), do: idx

    entries
    |> Enum.flat_map(fn
      {idx, %{tested: true, valued: false, tuple: tuple?}} ->
        if MapSet.member?(catch_all, idx), do: [], else: [if(tuple?, do: :tuple, else: :any)]

      _entry ->
        []
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc """
  Whether the function has a catch-all for the message in `register`
  that does nothing with it but report it. False without a catch-all.
  """
  @spec catch_all_drops?([tuple()], Instr.reg()) :: boolean()
  def catch_all_drops?(instrs, register) do
    tuple = List.to_tuple(instrs)
    labels = Dispatch.labels(instrs)

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
    tuple = List.to_tuple(instrs)
    labels = Dispatch.labels(instrs)
    start = (Enum.find_index(instrs, &match?({:func_info, _, _, _}, &1)) || -1) + 1

    path = %{
      tracked: %{Instr.register(register) => :msg},
      tested: false,
      passed: false,
      valued: false,
      tuple: false
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
    kinds = for a <- args, k = Map.get(path.tracked, reg(a)), do: k

    valued? =
      (op in @value_tests and Enum.any?(kinds, &(&1 in [:msg, :tag]))) or
        (op == :is_tagged_tuple and :msg in kinds)

    shaped? = op in @tuple_tests and :msg in kinds
    branch(idx, l, {kinds != [], valued?, shaped?}, path, tuple, labels, st)
  end

  defp step({:test, _op, {:f, l}, src, _fields}, idx, path, tuple, labels, st),
    do: branch(idx, l, {tracked?(path, src), false, false}, path, tuple, labels, st)

  # A fail-labelled map read is a test on its subject; its destinations
  # hold map values, not the message.
  defp step({:get_map_elements, {:f, l}, src, {:list, kvs}}, idx, path, tuple, labels, st) do
    on_message? = tracked?(path, src)
    tracked = kvs |> Enum.drop_every(2) |> Enum.reduce(path.tracked, &Map.delete(&2, reg(&1)))
    branch(idx, l, {on_message?, false, false}, %{path | tracked: tracked}, tuple, labels, st)
  end

  defp step({op, src, {:f, fail}, {:list, pairs}}, _idx, path, tuple, labels, st)
       when op in [:select_val, :select_tuple_arity] do
    kind = Map.get(path.tracked, reg(src))

    arm_path =
      if kind == nil,
        do: path,
        else: %{
          path
          | tested: true,
            passed: true,
            valued: path.valued or (op == :select_val and kind in [:msg, :tag]),
            tuple: path.tuple or (op == :select_tuple_arity and kind == :msg)
        }

    arms = pairs |> Enum.chunk_every(2) |> Enum.map(fn [_value, {:f, l}] -> {l, arm_path} end)

    default =
      case fail_path(kind != nil, path, fail, tuple, labels) do
        nil -> []
        p -> [{fail, p}]
      end

    Enum.reduce(arms ++ default, st, fn {l, p}, st -> goto(l, p, tuple, labels, st) end)
  end

  defp step({:jump, {:f, l}}, _idx, path, tuple, labels, st), do: goto(l, path, tuple, labels, st)

  defp step({:move, src, dst}, idx, path, tuple, labels, st),
    do: walk(idx + 1, %{path | tracked: track(path.tracked, src, dst, nil)}, tuple, labels, st)

  defp step({:swap, a, b}, idx, path, tuple, labels, st) do
    ka = Map.get(path.tracked, reg(a))
    kb = Map.get(path.tracked, reg(b))
    tracked = path.tracked |> Map.delete(reg(a)) |> Map.delete(reg(b))
    tracked = if ka, do: Map.put(tracked, reg(b), ka), else: tracked
    tracked = if kb, do: Map.put(tracked, reg(a), kb), else: tracked
    walk(idx + 1, %{path | tracked: tracked}, tuple, labels, st)
  end

  defp step({:get_tuple_element, src, i, dst}, idx, path, tuple, labels, st) do
    kind = if Map.get(path.tracked, reg(src)) == :msg and i == 0, do: :tag, else: :part
    walk(idx + 1, %{path | tracked: track(path.tracked, src, dst, kind)}, tuple, labels, st)
  end

  defp step({op, src, dst}, idx, path, tuple, labels, st) when op in [:get_hd, :get_tl],
    do: walk(idx + 1, %{path | tracked: track(path.tracked, src, dst, :part)}, tuple, labels, st)

  # The failure exit: not a clause.
  defp step({:func_info, _, _, _}, _idx, _path, _tuple, _labels, st), do: st

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

  defp branch(idx, fail, {on_message?, valued?, shaped?}, path, tuple, labels, st) do
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

    case fail_path(on_message?, path, fail, tuple, labels) do
      nil -> st
      p -> goto(fail, p, tuple, labels, st)
    end
  end

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
    case {reg(src), reg(dst)} do
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

  defp tracked?(path, operand), do: Map.has_key?(path.tracked, reg(operand))

  defp reg({:tr, r, _type}), do: reg(r)
  defp reg({kind, _} = r) when kind in [:x, :y], do: r
  defp reg(_other), do: nil

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
