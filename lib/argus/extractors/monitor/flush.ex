defmodule Argus.Extractors.Monitor.Flush do
  @moduledoc """
  Whether a receive runs only where a `cancel_timer` earlier in its
  function returned `false`.

  `:erlang.cancel_timer/1,2` returns `false` when the timer had already
  fired: its message is in the mailbox, and a receive that takes it
  cannot wait. The idiom tests the result and receives on the `false`
  side (Livebook's session, gen_server's `mc_cancel_timer/2`):

      case erlang:cancel_timer(Ref) of
          false -> receive {timeout, Ref, _} -> ok end;
          _ -> ok
      end

  A cancel whose result nothing tests, and a receive the other side of
  the test also reaches, are no flush: when the cancel succeeded, the
  message never comes. Read on the function's graph. The result is
  followed from the call, through moves, to the first test that compares
  it with `false` (`is_eq_exact`, `is_ne_exact`, `is_eq`, `is_ne`,
  `select_val`); anything else first — another call, a write over the
  register — and the cancel has no `false` side here. A receive is the
  flush when the `false` edge reaches it, and neither the test's other
  edges nor a path from the entry that skips the test do. A receive in a
  helper the `false` side calls is not seen.
  """

  alias Argus.Cfg.Function
  alias Argus.Cfg.Walk
  alias Argus.Extractor.Dispatch
  alias Argus.Instr

  import Argus.Extractor.Helpers, only: [match_remote_call: 1]
  import Argus.Instr, only: [register: 1]

  # The result is looked for this many instructions after the call.
  @max_steps 16

  @doc """
  Each `{loop_rec, cancel}` pair of instruction indices in the function
  whose instructions are `instrs` and whose graph is `fun`: the receive
  at `loop_rec` runs only where the `cancel_timer` call at `cancel`
  returned `false`.
  """
  @spec guarded([tuple()], Function.t() | nil) :: [{non_neg_integer(), non_neg_integer()}]
  def guarded(_instrs, nil), do: []

  def guarded(instrs, %Function{} = fun) do
    indexed = Enum.with_index(instrs)

    with [_ | _] = loops <- for({{:loop_rec, _, _}, idx} <- indexed, do: idx),
         [_ | _] = cancels <- for({instr, idx} <- indexed, cancel?(instr), do: idx) do
      ctx = %{code: List.to_tuple(instrs), labels: Instr.labels(instrs)}

      for cancel <- cancels,
          {:ok, test, falses, others} <- [false_side(ctx, cancel)],
          flushed = flushed(fun, instrs, loops, test, falses, others),
          loop <- flushed,
          do: {loop, cancel}
    else
      _ -> []
    end
  end

  defp flushed(fun, instrs, loops, test, falses, others) do
    {:done, on_false} = Walk.explore(fun, instrs, falses, [])
    {:done, on_other} = Walk.explore(fun, instrs, others, [])

    {:done, skipping} =
      Walk.explore(fun, instrs, [Dispatch.entry_index(instrs)],
        on_instr: fn _instr, idx -> if idx == test, do: :prune, else: :continue end
      )

    Enum.filter(loops, fn loop ->
      MapSet.member?(on_false, loop) and not MapSet.member?(on_other, loop) and
        not MapSet.member?(skipping, loop)
    end)
  end

  defp cancel?(instr) do
    case match_remote_call(instr) do
      {:ok, mod, :cancel_timer, arity} -> mod in [:erlang, Process] and arity in [1, 2]
      _ -> false
    end
  end

  # The test that compares the cancel's result with `false`, and where
  # each side of it starts: `{:ok, test, false_starts, other_starts}`.
  # `held` is the registers holding the result: a short list.
  defp false_side(ctx, cancel), do: step(ctx, cancel + 1, [{:x, 0}], 0)

  defp step(_ctx, _idx, _held, steps) when steps > @max_steps, do: :none

  defp step(ctx, idx, held, steps) when idx < tuple_size(ctx.code) do
    case elem(ctx.code, idx) do
      {:line, _} ->
        step(ctx, idx + 1, held, steps + 1)

      {:move, src, dst} ->
        held =
          if register(src) in held,
            do: [register(dst) | held],
            else: List.delete(held, register(dst))

        step(ctx, idx + 1, held, steps + 1)

      {:test, op, {:f, l}, [a, b]} when op in [:is_eq_exact, :is_eq, :is_ne_exact, :is_ne] ->
        compared(ctx, idx, op, l, a, b, held)

      {:select_val, src, {:f, l}, {:list, pairs}} ->
        if register(src) in held, do: selected(ctx, idx, l, pairs), else: :none

      _ ->
        :none
    end
  end

  defp step(_ctx, _idx, _held, _steps), do: :none

  defp compared(ctx, idx, op, l, a, b, held) do
    against_false? =
      (register(a) in held and b == {:atom, false}) or
        (register(b) in held and a == {:atom, false})

    with true <- against_false?, {:ok, target} <- Map.fetch(ctx.labels, l) do
      if op in [:is_eq_exact, :is_eq],
        do: {:ok, idx, [idx + 1], [target]},
        else: {:ok, idx, [target], [idx + 1]}
    else
      _ -> :none
    end
  end

  defp selected(ctx, idx, fail, pairs) do
    targets =
      pairs
      |> Enum.chunk_every(2)
      |> Enum.flat_map(fn
        [value, {:f, l}] -> [{value, Map.get(ctx.labels, l)}]
        _ -> []
      end)

    case for({{:atom, false}, at} <- targets, at != nil, do: at) do
      [at] ->
        others = [Map.get(ctx.labels, fail) | for({_, other} <- targets, other != at, do: other)]
        {:ok, idx, [at], others}

      _ ->
        :none
    end
  end
end
