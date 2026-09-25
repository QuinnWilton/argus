defmodule Argus.Extractors.Monitor.ExitSignal do
  @moduledoc """
  Whether a receive takes a particular process's exit signal, whatever
  the reason it exits with.

  A receive with a clause for `{:DOWN, ^ref, _, _, _}` ends no later than
  the process `ref` monitors does: the runtime sends that `:DOWN` once
  the process exits, or at once if it was already gone. One with a clause
  for `{:EXIT, ^pid, _}` ends no later than the process or port it is
  linked to, in a process that traps exits (in one that does not, an
  abnormal exit ends the waiter with it). `recv_down` asks the first of a
  monitor the receive's own function took; this asks it of the receive
  alone, wherever the pinned value came from: a parameter (proc_lib's
  `await_DOWN(pid, ref)`, mnesia's `rec(pid, ref)`), a `spawn_monitor`'s
  pair (code's `do_par/2`), a monitor with a tag of its own (gen_server's
  multi_call waits for `{alias, ref, :process, _, _}`), a port the
  function opened and closed (peer's init/1 waits for the port's
  `{:EXIT, port, _}`).

  The clause heads are run on the signal of the process the pinned
  register names: `{tag, ref, type, object, reason}` for a :DOWN,
  `{:EXIT, from, reason}` for an exit signal. The tag is `:DOWN` (or,
  for a :DOWN, a register the monitor's `{:tag, t}` option named, with
  the type a literal `:process` or `:port`), the type is either of those,
  and the ref (the sender) is what the register it is compared with
  holds: that comparison is the pin, and a clause without one waits for
  any process, which is not asked here. The object equals the register
  it is compared with — the pid the monitor was taken on; a monitor by
  name reports `{name, node}` instead, and a pin on the name misses it
  (a bug of its own, which this does not see). The reason is anything:
  a test on it takes only its failure edge, since some reason fails it.
  A test on anything else — a guard on the state — takes both edges.
  """

  alias Argus.Instr

  import Argus.Extractor.Helpers, only: [register: 1]

  # The decision tree of a receive's heads is small; the bound keeps a
  # malformed one from walking forever.
  @max_states 500

  @shapes [down: 5, exit: 3]

  @doc """
  The exit signals (`"down"`, `"exit"`) some clause of the receive whose
  `loop_rec` is at `loop` takes, for the process a pinned register
  names. `code` is the function's instructions as a tuple, `labels` its
  label → index map.
  """
  @spec signals(tuple(), %{non_neg_integer() => non_neg_integer()}, non_neg_integer()) ::
          [String.t()]
  def signals(code, labels, loop) do
    {:loop_rec, _fail, dst} = elem(code, loop)
    ctx = %{code: code, labels: labels}

    for {shape, arity} <- @shapes,
        start = %{
          idx: loop + 1,
          regs: %{register(dst) => :msg},
          shape: shape,
          arity: arity,
          tag: nil,
          type: false,
          pinned: false
        },
        walk([start], ctx, %{}),
        do: to_string(shape)
  end

  defp walk([], _ctx, _seen), do: false
  defp walk(_states, _ctx, seen) when map_size(seen) > @max_states, do: false

  defp walk([state | rest], ctx, seen) do
    key = Map.take(state, [:idx, :regs, :tag, :type, :pinned])

    if state.idx >= tuple_size(ctx.code) or Map.has_key?(seen, key) do
      walk(rest, ctx, seen)
    else
      case step(elem(ctx.code, state.idx), state, ctx) do
        :taken -> taken?(state) or walk(rest, ctx, Map.put(seen, key, true))
        next -> walk(next ++ rest, ctx, Map.put(seen, key, true))
      end
    end
  end

  # The clause that took the message took the signal of the pinned process.
  defp taken?(%{pinned: true, tag: :literal}), do: true
  defp taken?(%{pinned: true, tag: :register, shape: :down, type: true}), do: true
  defp taken?(_state), do: false

  # ── Steps ────────────────────────────────────────────────────────

  defp step(:remove_message, _state, _ctx), do: :taken
  defp step({:loop_rec_end, _}, _state, _ctx), do: []
  defp step({:wait, _}, _state, _ctx), do: []
  defp step({:wait_timeout, _, _}, _state, _ctx), do: []
  defp step(:timeout, _state, _ctx), do: []
  defp step({:jump, {:f, l}}, state, ctx), do: goto(state, l, ctx)

  defp step({:move, src, dst}, state, _ctx) do
    regs =
      case value(src, state) do
        {:msg_part, part} -> Map.put(state.regs, register(dst), part)
        _ -> Map.delete(state.regs, register(dst))
      end

    [%{state | idx: state.idx + 1, regs: regs}]
  end

  defp step({:get_tuple_element, src, n, dst}, state, _ctx) do
    regs =
      if value(src, state) == {:msg_part, :msg},
        do: Map.put(state.regs, register(dst), {:elem, n}),
        else: Map.delete(state.regs, register(dst))

    [%{state | idx: state.idx + 1, regs: regs}]
  end

  defp step({:test, op, {:f, l}, [a, b]}, state, ctx) when op in [:is_eq_exact, :is_ne_exact] do
    case compare(value(a, state), value(b, state), state) do
      {:equal, state} -> branch(op == :is_eq_exact, state, l, ctx)
      :differ -> branch(op != :is_eq_exact, state, l, ctx)
      :unknown -> pass(state) ++ goto(state, l, ctx)
    end
  end

  defp step({:test, :is_tagged_tuple, {:f, l}, [r, n, tag]}, state, ctx) do
    case value(r, state) do
      {:msg_part, :msg} ->
        case tag_literal(tag, state) do
          true when n == state.arity -> pass(%{state | tag: :literal})
          _ -> goto(state, l, ctx)
        end

      {:msg_part, _part} ->
        goto(state, l, ctx)

      _ ->
        pass(state) ++ goto(state, l, ctx)
    end
  end

  defp step({:test, :test_arity, {:f, l}, [r, n]}, state, ctx) do
    case value(r, state) do
      {:msg_part, :msg} -> if n == state.arity, do: pass(state), else: goto(state, l, ctx)
      {:msg_part, _part} -> goto(state, l, ctx)
      _ -> pass(state) ++ goto(state, l, ctx)
    end
  end

  defp step({:test, op, {:f, l}, [r]}, state, ctx) do
    case value(r, state) do
      {:msg_part, part} -> type_test(op, part, state, l, ctx)
      _ -> pass(state) ++ goto(state, l, ctx)
    end
  end

  defp step({:select_tuple_arity, r, {:f, fail}, {:list, pairs}}, state, ctx) do
    case value(r, state) do
      {:msg_part, :msg} -> goto(state, arm(pairs, state.arity, fail), ctx)
      {:msg_part, _part} -> goto(state, fail, ctx)
      _ -> all_arms(pairs, fail, state, ctx)
    end
  end

  defp step({:select_val, r, {:f, fail}, {:list, pairs}}, state, ctx) do
    case value(r, state) do
      {:msg_part, {:elem, 0}} ->
        atom = tag_atom(state.shape)
        tagged = %{state | tag: :literal}

        case arm(pairs, {:atom, atom}, fail) do
          ^fail -> goto(state, fail, ctx)
          l -> goto(tagged, l, ctx)
        end

      {:msg_part, {:elem, 2}} when state.shape == :down ->
        arms =
          for [value, {:f, l}] <- Enum.chunk_every(pairs, 2),
              value in [{:atom, :process}, {:atom, :port}],
              do: l

        Enum.flat_map(arms, &goto(%{state | type: true}, &1, ctx)) ++ goto(state, fail, ctx)

      # A tuple is no atom or number; a reason (or any other part) is
      # anything, and some value takes the default.
      {:msg_part, _part} ->
        goto(state, fail, ctx)

      _ ->
        all_arms(pairs, fail, state, ctx)
    end
  end

  # Between the tests and remove_message the compiler binds variables and
  # reserves heap: what neither branches nor calls cannot refuse the
  # message. A guard BIF with a fail label may; both edges are taken.
  defp step(instr, state, ctx) do
    if not Instr.known?(instr) or Instr.call?(instr) or Instr.tail_call?(instr) do
      []
    else
      next = %{state | regs: Map.drop(state.regs, Instr.defs(instr))}
      fall = if Instr.falls_through?(instr), do: pass(next), else: []
      fall ++ Enum.flat_map(Instr.targets(instr), &goto(next, &1, ctx))
    end
  end

  # ── What an operand holds ────────────────────────────────────────

  # `{:msg_part, part}` for the message (`:msg`) or one of its elements
  # (`{:elem, n}`), `{:lit, term}` for a literal, `:reg` for a register
  # the heads did not fill.
  defp value({:atom, a}, _state), do: {:lit, a}
  defp value({:integer, i}, _state), do: {:lit, i}
  defp value({:float, f}, _state), do: {:lit, f}
  defp value({:literal, term}, _state), do: {:lit, term}
  defp value(nil, _state), do: {:lit, []}

  defp value(operand, state) do
    case Map.fetch(state.regs, register(operand)) do
      {:ok, part} -> {:msg_part, part}
      :error -> :reg
    end
  end

  # Whether a message part equals the other operand on the signal being
  # modelled: `{:equal, state}` (with what the answer established),
  # `:differ`, or `:unknown` when neither side is the message.
  defp compare({:msg_part, part}, other, state), do: compare_part(part, other, state)
  defp compare(other, {:msg_part, part}, state), do: compare_part(part, other, state)
  defp compare(_a, _b, _state), do: :unknown

  defp compare_part({:elem, 0}, {:lit, tag}, state) do
    if tag == tag_atom(state.shape), do: {:equal, %{state | tag: :literal}}, else: :differ
  end

  # A monitor's own tag, which a register holds (`[{:tag, alias}]`).
  defp compare_part({:elem, 0}, :reg, %{shape: :down} = state),
    do: {:equal, %{state | tag: :register}}

  defp compare_part({:elem, 1}, :reg, state), do: {:equal, %{state | pinned: true}}

  defp compare_part({:elem, 2}, {:lit, type}, %{shape: :down} = state)
       when type in [:process, :port],
       do: {:equal, %{state | type: true}}

  defp compare_part({:elem, 3}, :reg, %{shape: :down} = state), do: {:equal, state}

  # Anything else is not the modelled signal, or not all of it: a ref or
  # a sender equals no literal, and the reason is anything, so some value
  # fails the test.
  defp compare_part(_part, _other, _state), do: :differ

  defp type_test(:is_tuple, :msg, state, _l, _ctx), do: pass(state)

  defp type_test(:is_atom, {:elem, n}, %{shape: :down} = state, _l, _ctx) when n in [0, 2],
    do: pass(state)

  defp type_test(:is_atom, {:elem, 0}, state, _l, _ctx), do: pass(state)
  defp type_test(:is_reference, {:elem, 1}, %{shape: :down} = state, _l, _ctx), do: pass(state)

  # The sender of an exit signal, and a :DOWN's object, is a pid or a
  # port (or, for a monitor by name, a tuple): a test of its type may
  # pass.
  defp type_test(op, {:elem, 1}, %{shape: :exit} = state, l, ctx)
       when op in [:is_pid, :is_port],
       do: pass(state) ++ goto(state, l, ctx)

  defp type_test(op, {:elem, 3}, %{shape: :down} = state, l, ctx)
       when op in [:is_pid, :is_port, :is_tuple],
       do: pass(state) ++ goto(state, l, ctx)

  defp type_test(_op, _part, state, l, ctx), do: goto(state, l, ctx)

  # ── Edges ────────────────────────────────────────────────────────

  defp branch(true, state, _l, _ctx), do: pass(state)
  defp branch(false, state, l, ctx), do: goto(state, l, ctx)

  defp pass(state), do: [%{state | idx: state.idx + 1}]

  defp goto(state, label, ctx) do
    case Map.fetch(ctx.labels, label) do
      {:ok, idx} -> [%{state | idx: idx}]
      :error -> []
    end
  end

  defp all_arms(pairs, fail, state, ctx) do
    labels = for [_value, {:f, l}] <- Enum.chunk_every(pairs, 2), do: l
    Enum.flat_map([fail | labels], &goto(state, &1, ctx))
  end

  defp arm([value, {:f, l} | _rest], value, _fail), do: l
  defp arm([_value, _label | rest], value, fail), do: arm(rest, value, fail)
  defp arm(_pairs, _value, fail), do: fail

  defp tag_atom(:down), do: :DOWN
  defp tag_atom(:exit), do: :EXIT

  defp tag_literal({:atom, atom}, state), do: atom == tag_atom(state.shape)
  defp tag_literal(_tag, _state), do: false
end
