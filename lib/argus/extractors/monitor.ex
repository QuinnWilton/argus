defmodule Argus.Extractors.Monitor do
  @moduledoc """
  Monitor and demonitor call sites.

  A monitor is a promise the runtime keeps: once `Process.monitor/1`
  returns, a `{:DOWN, ref, :process, object, reason}` message **will** arrive
  unless the monitor is cancelled. Nothing in the calling code says so, and
  the message can arrive arbitrarily later — after a `receive` gave up
  waiting, after the state machine moved on, after the reason stopped
  meaning anything.

  Two consequences, and both are structural.

  `Process.demonitor(ref)` cancels, but a `{:DOWN, ...}` already in the
  mailbox stays there; only `Process.demonitor(ref, [:flush])` removes it.
  So the flush option is recorded separately — it is the difference between
  cancelling a future message and cancelling a message that has already been
  sent.

  And a process that monitors is a process that receives `:DOWN`. That makes
  "will this specific message arrive?" answerable for once, where in general
  it is not: the analysis need not guess what lands in a mailbox if the code
  asked for it.

  ## Emitted facts

  - `monitor_call(id, func, target)` — a monitor is established
  - `monitor_ref_dropped(id, func)` — the reference that monitor returned
    is discarded at the call site, so nothing can ever demonitor it
  - `demonitor_call(id, func, flush)` — `flush` is `"flush"` or `"no_flush"`

  Whether the ref is dropped is read from the instructions after the
  call, along every path: the ref arrives in `{x, 0}`, and it is dropped
  when on each path the next thing to happen to that register is a write
  that does not read it — a move of something else into it, a zero-arity
  call, a tuple built into it from other registers, a `test_heap`
  declaring no live registers. A read on any path, a return, and anything
  the scan does not understand count as kept, which is the direction
  that keeps the fact honest.
  """

  @behaviour Argus.Extractor

  alias Argus.InstrId

  import Argus.Extractor.Helpers,
    only: [add_fact: 3, match_remote_call: 1, resolve_atom: 3, scan_functions: 4]

  @impl true
  def extract(%{module: mod, functions: functions}) do
    scan_functions(mod, functions, %{}, fn facts, ctx, instr ->
      case match_remote_call(instr) do
        {:ok, m, f, a} -> handle(facts, ctx, {m, f, a})
        :none -> facts
      end
    end)
  end

  defp handle(facts, ctx, {Process, :monitor, 1}), do: monitor(facts, ctx)
  defp handle(facts, ctx, {:erlang, :monitor, 2}), do: monitor(facts, ctx)

  defp handle(facts, ctx, {Process, :demonitor, arity}) when arity in [1, 2],
    do: demonitor(facts, ctx, arity)

  defp handle(facts, ctx, {:erlang, :demonitor, arity}) when arity in [1, 2],
    do: demonitor(facts, ctx, arity)

  defp handle(facts, _ctx, _mfa), do: facts

  defp monitor(facts, ctx) do
    id = InstrId.mint(ctx.func_id, ctx.idx)

    facts =
      add_fact(facts, :monitor_call, [id, ctx.func_id, resolve_atom(ctx.instrs, ctx.idx, {:x, 0})])

    if ref_dropped?(ctx.instrs, ctx.idx + 1),
      do: add_fact(facts, :monitor_ref_dropped, [id, ctx.func_id]),
      else: facts
  end

  @x0 {:x, 0}

  # Walks forward from the call along every path. Each instruction
  # either reads {x,0} (the ref is kept, and the answer is no), writes it
  # without reading (this path is done, the ref is gone on it), touches
  # it not at all (keep looking), branches (follow every way out), or is
  # something with x0 in a position whose meaning is unknown — and that
  # is "kept": a fact claiming a ref is gone must be sure. The ref is
  # dropped when no path reaches a read.
  defp ref_dropped?(instrs, start) do
    indexed = Enum.with_index(instrs)
    by_idx = Map.new(indexed, fn {instr, idx} -> {idx, instr} end)
    labels = Map.new(for {{:label, l}, idx} <- indexed, do: {l, idx})
    walk([start], by_idx, labels, length(instrs), %{})
  end

  defp walk([], _by_idx, _labels, _len, _seen), do: true

  defp walk([idx | rest], by_idx, labels, len, seen) do
    if is_nil(idx) or idx >= len or Map.has_key?(seen, idx) do
      walk(rest, by_idx, labels, len, seen)
    else
      instr = Map.fetch!(by_idx, idx)
      seen = Map.put(seen, idx, true)

      case classify(instr) do
        :reads -> false
        :unknown -> false
        :writes -> walk(rest, by_idx, labels, len, seen)
        :neutral -> walk(successors(instr, idx, labels) ++ rest, by_idx, labels, len, seen)
      end
    end
  end

  defp successors({:jump, {:f, l}}, _idx, labels), do: List.wrap(Map.get(labels, l))

  defp successors({:test, _, {:f, l}, _}, idx, labels),
    do: [idx + 1 | List.wrap(Map.get(labels, l))]

  defp successors({:test, _, {:f, l}, _, _}, idx, labels),
    do: [idx + 1 | List.wrap(Map.get(labels, l))]

  defp successors({op, _, {:f, l}, {:list, entries}}, _idx, labels)
       when op in [:select_val, :select_tuple_arity] do
    targets = for {:f, t} <- entries, at = Map.get(labels, t), do: at
    targets ++ List.wrap(Map.get(labels, l))
  end

  # An error exit: the ref was never read on this path.
  defp successors({:func_info, _, _, _}, _idx, _labels), do: []
  defp successors({:badmatch, _}, _idx, _labels), do: []
  defp successors({:case_end, _}, _idx, _labels), do: []
  defp successors(:if_end, _idx, _labels), do: []
  defp successors(_instr, idx, _labels), do: [idx + 1]

  defp classify({:line, _}), do: :neutral
  defp classify({:allocate, _, _}), do: :neutral
  defp classify({:allocate_heap, _, _, _}), do: :neutral
  defp classify({:init_yregs, _}), do: :neutral
  defp classify({:trim, _, _}), do: :neutral
  defp classify({:test_heap, _words, 0}), do: :writes
  defp classify({:test_heap, _words, _live}), do: :neutral
  defp classify(:return), do: :reads
  defp classify({:deallocate, _}), do: :reads
  defp classify({:move, src, dst}), do: rw([src], [dst])
  defp classify({:put_tuple2, dst, {:list, elements}}), do: rw(elements, [dst])
  defp classify({:put_list, head, tail, dst}), do: rw([head, tail], [dst])
  defp classify({:get_tuple_element, src, _idx, dst}), do: rw([src], [dst])

  defp classify({:get_map_elements, _fail, src, {:list, pairs}}),
    do: rw([src], pairs |> Enum.drop(1) |> Enum.take_every(2))

  defp classify({op, _fail, src, dst, _live, {:list, pairs}})
       when op in [:put_map_assoc, :put_map_exact],
       do: rw([src | pairs], [dst])

  defp classify({:bif, _name, _fail, args, dst}), do: rw(args, [dst])
  defp classify({:gc_bif, _name, _fail, _live, args, dst}), do: rw(args, [dst])
  defp classify({:call, arity, _}), do: call(arity)
  defp classify({:call_ext, arity, _}), do: call(arity)
  defp classify({:call_only, arity, _}), do: call(arity)
  defp classify({:call_ext_only, arity, _}), do: call(arity)
  defp classify({:call_last, arity, _, _}), do: call(arity)
  defp classify({:call_ext_last, arity, _, _}), do: call(arity)
  defp classify({:call_fun, arity}), do: call(arity + 1)
  defp classify({:apply, arity}), do: call(arity + 2)

  defp classify(instr), do: if(mentions_x0?(instr), do: :unknown, else: :neutral)

  # A call reads its arguments positionally from {x,0} up; with none,
  # its result overwrites {x,0}.
  defp call(0), do: :writes
  defp call(_arity), do: :reads

  defp rw(reads, writes) do
    cond do
      Enum.any?(reads, &(register(&1) == @x0)) -> :reads
      Enum.any?(writes, &(register(&1) == @x0)) -> :writes
      true -> :neutral
    end
  end

  defp mentions_x0?(term) when is_tuple(term) do
    register(term) == @x0 or term |> Tuple.to_list() |> Enum.any?(&mentions_x0?/1)
  end

  defp mentions_x0?(term) when is_list(term), do: Enum.any?(term, &mentions_x0?/1)
  defp mentions_x0?(_term), do: false

  defp register({:tr, reg, _type}), do: reg
  defp register(reg), do: reg

  # demonitor/1 cannot flush — the option list is the only way — so arity is
  # a sound lower bound on the answer. For arity 2 the list is read when it
  # is a literal, and anything else is "no_flush", which is the direction
  # that keeps a finding rather than silently discharging one.
  defp demonitor(facts, ctx, 1) do
    add_fact(facts, :demonitor_call, [
      InstrId.mint(ctx.func_id, ctx.idx),
      ctx.func_id,
      "no_flush"
    ])
  end

  defp demonitor(facts, ctx, 2) do
    add_fact(facts, :demonitor_call, [
      InstrId.mint(ctx.func_id, ctx.idx),
      ctx.func_id,
      flush_option(ctx.instrs, ctx.idx)
    ])
  end

  defp flush_option(instrs, idx) do
    instrs
    |> Enum.take(idx)
    |> Enum.reverse()
    |> Enum.find_value("no_flush", fn
      {:move, {:literal, opts}, {:x, 1}} when is_list(opts) ->
        if :flush in opts, do: "flush", else: "no_flush"

      {:move, _src, {:x, 1}} ->
        "no_flush"

      _ ->
        false
    end)
  end
end
