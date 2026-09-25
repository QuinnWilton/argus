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

  - `monitor_call(id, func, target)` — a monitor is established; `target`
    is the monitored name when literal, `"started_child"` when the pid is
    the result of a supervisor start (directly or through a local
    wrapper), else `"dynamic"`
  - `monitor_ref_dropped(id, func)` — the reference that monitor returned
    is discarded at the call site, so nothing can ever demonitor it
  - `demonitor_call(id, func, flush)` — `flush` is `"flush"` or `"no_flush"`
  - `recv_down(id, func, monitor)` — a receive with a clause that takes
    the `:DOWN` of the monitor its function took at `monitor`, so it ends
    no later than the monitored process does
  - `matches_down(func)` — the function's clause heads (or a `case` on an
    argument, before any call) compare to `:DOWN`, so it is (part of) a
    :DOWN handler; unlike `callback_tag` this is emitted for every
    function, because a gen_statem funnels its :info events into private
    helpers that no callback name identifies
  - `awaits_down_after(func, call)` — every path in `func` from the call
    at `call` to its return waits for a `:DOWN` (below)
  - `recv_signal(id, func, signal)` — a receive with a clause that takes
    the exit signal of the process a pinned register names, whatever its
    reason: a `:DOWN` (`"down"`) or an `:EXIT` (`"exit"`)
    (`Argus.Extractors.Monitor.ExitSignal`)

  Whether the ref is dropped is read from the instructions after the
  call, along every path: the ref arrives in `{x, 0}`, and it is dropped
  when on each path the next thing to happen to that register is a write
  that does not read it — a move of something else into it, a zero-arity
  call, a tuple built into it from other registers, a `test_heap`
  declaring no live registers. A read on any path, a return, and anything
  the scan does not understand count as kept, which is the direction
  that keeps the fact honest.

  ## A monitor the caller collects

  A function may take a monitor and return with it live on purpose: its
  caller goes on to wait for the `:DOWN`. OTP's old supervisor shutdown,
  copied into GenStage's ConsumerSupervisor and Horde's
  ProcessesSupervisor, monitors each child in `monitor_child/1`, looks
  once (`after 0`) for an `{:EXIT, ...}` already in the mailbox, and
  returns; its caller then blocks in `wait_children` until every child's
  `{:DOWN, ...}` has come. `awaits_down_after(func, call)` names the
  calls such a wait follows on every path to `func`'s return: a receive
  with no `after` whose `{:DOWN, ...}` clause takes any monitor's (the
  ref is not compared), or the one whose ref the call returned; a
  `Process.demonitor(ref, [:flush])` of that ref; or a call to a function
  of this module that holds such a receive, or calls one that does. A
  path that raises is not asked: the wait was for a caller that is
  unwinding. A receive in a closure, and a wait in another module, are
  not seen, and leave the call without a row.

  ## A receive that takes its own monitor's :DOWN

  Whether a receive takes its own monitor's `:DOWN` is read by running
  the receive's clause heads on that message, `{:DOWN, ref, type, object,
  reason}` with only the tag, the ref and the type known: each test is
  decided by what is known or the answer is no. A pin on the object (a
  monitor by name reports `{name, node}`, not a pid), a reason, a guard
  — anything that could refuse the message — is no. The pinned ref must
  be, on every path to the comparison, what a monitor call in the same
  function returned (`Argus.Extractor.Resolve.trace/5`), and no path from
  that call to the receive may demonitor.
  """

  @behaviour Argus.Extractor

  alias Argus.Cfg.Walk
  alias Argus.Extractor.Resolve
  alias Argus.Extractors.Monitor.ExitSignal
  alias Argus.Instr
  alias Argus.InstrId

  import Argus.Extractor.Helpers,
    only: [
      cfg: 2,
      cfg: 3,
      each_remote_call: 3,
      match_local_call: 1,
      match_remote_call: 1,
      register: 1
    ]

  import Argus.Extractor.Facts, only: [add_fact: 3]
  import Argus.Extractor.Resolve, only: [resolve_atom: 3]
  import Argus.Extractor.Terms, only: [list_elements: 1]

  @impl true
  def relations,
    do: [
      :awaits_down_after,
      :demonitor_call,
      :matches_down,
      :monitor_call,
      :monitor_ref_dropped,
      :recv_down,
      :recv_signal
    ]

  @impl true
  def extract(%{module: mod, functions: functions} = module_data) do
    module_data
    |> each_remote_call(%{}, &handle(&1, &2, &3, module_data))
    |> emit_matches_down(mod, functions)
    |> emit_awaits_down_after(module_data)
    |> emit_recv_down(module_data)
    |> emit_recv_signal(mod, functions)
  end

  # ── A receive that ends when a particular process does ───────────────

  # A function that calls itself is a loop, and the `{:EXIT, parent, _}`
  # clause of a loop's receive ends the loop, not a wait for a reply: the
  # loop waits for its next message, from anyone. Its :DOWN clauses stay
  # (gen_server's multi_call waits for one reply or :DOWN per call of
  # itself). A loop through another function is not seen.
  defp emit_recv_signal(facts, mod, functions) do
    Enum.reduce(functions, facts, fn {:function, name, arity, _entry, instrs}, acc ->
      case for({{:loop_rec, _fail, _dst}, idx} <- Enum.with_index(instrs), do: idx) do
        [] ->
          acc

        receives ->
          func_id = InstrId.func_id(mod, name, arity)
          code = List.to_tuple(instrs)
          labels = labels(instrs)
          loops? = Enum.any?(instrs, &(match_local_call(&1) == {:ok, mod, name, arity}))

          for loop <- receives,
              signal <- ExitSignal.signals(code, labels, loop),
              not (loops? and signal == "exit"),
              reduce: acc do
            acc -> add_fact(acc, :recv_signal, [InstrId.mint(func_id, loop), func_id, signal])
          end
      end
    end)
  end

  defp emit_matches_down(facts, mod, functions) do
    Enum.reduce(functions, facts, fn {:function, name, arity, _entry, instrs}, acc ->
      if head_matches_down?(instrs, arity),
        do: add_fact(acc, :matches_down, [InstrId.func_id(mod, name, arity)]),
        else: acc
    end)
  end

  # A comparison to :DOWN on an argument register, or a register copied or
  # projected from one, in a clause head: the function's clauses (or a
  # `case` on its message argument) discriminate on :DOWN. A :DOWN
  # compared deeper in a body — a helper's result, a logged reason — is
  # not what makes a function the handler.
  #
  # Clauses are laid out one after another, each body's calls between
  # one head and the next, so the scan is linear over the function: a
  # call clobbers the x registers it tracks, and the fail label of a head
  # test starts the next clause, where the arguments are live again.
  defp head_matches_down?(instrs, arity) do
    args = MapSet.new(for i <- 0..(arity - 1)//1, do: {:x, i})

    {found?, _tracked, _heads} =
      Enum.reduce_while(instrs, {false, args, MapSet.new()}, fn instr, {_, tracked, heads} ->
        case head_step(instr, tracked, heads, args) do
          :down -> {:halt, {true, tracked, heads}}
          {tracked, heads} -> {:cont, {false, tracked, heads}}
        end
      end)

    found?
  end

  defp head_step({:test, :is_eq_exact, {:f, l}, [a, b]}, tracked, heads, _args) do
    cond do
      (tracked?(a, tracked) and b == {:atom, :DOWN}) or
          (tracked?(b, tracked) and a == {:atom, :DOWN}) ->
        :down

      tracked?(a, tracked) or tracked?(b, tracked) ->
        {tracked, MapSet.put(heads, l)}

      true ->
        {tracked, heads}
    end
  end

  defp head_step({:test, :is_tagged_tuple, {:f, l}, [src, _n, tag]}, tracked, heads, _args) do
    cond do
      tracked?(src, tracked) and tag == {:atom, :DOWN} -> :down
      tracked?(src, tracked) -> {tracked, MapSet.put(heads, l)}
      true -> {tracked, heads}
    end
  end

  defp head_step({:test, _op, {:f, l}, args}, tracked, heads, _args) when is_list(args) do
    if Enum.any?(args, &tracked?(&1, tracked)),
      do: {tracked, MapSet.put(heads, l)},
      else: {tracked, heads}
  end

  defp head_step({:test, _op, {:f, l}, src, _fields}, tracked, heads, _args) do
    if tracked?(src, tracked), do: {tracked, MapSet.put(heads, l)}, else: {tracked, heads}
  end

  defp head_step({:select_val, src, {:f, l}, {:list, pairs}}, tracked, heads, _args) do
    cond do
      tracked?(src, tracked) and {:atom, :DOWN} in Enum.take_every(pairs, 2) -> :down
      tracked?(src, tracked) -> {tracked, MapSet.put(heads, l)}
      true -> {tracked, heads}
    end
  end

  defp head_step({:label, l}, tracked, heads, args) do
    if MapSet.member?(heads, l), do: {args, heads}, else: {tracked, heads}
  end

  defp head_step({:move, src, dst}, tracked, heads, _args), do: {track(tracked, src, dst), heads}

  defp head_step({:get_tuple_element, src, _i, dst}, tracked, heads, _args),
    do: {track(tracked, src, dst), heads}

  defp head_step({:get_hd, src, dst}, tracked, heads, _args),
    do: {track(tracked, src, dst), heads}

  defp head_step({call, _, _}, tracked, heads, _args)
       when call in [:call, :call_ext, :call_only, :call_ext_only],
       do: {drop_x(tracked), heads}

  defp head_step({:call_fun, _}, tracked, heads, _args), do: {drop_x(tracked), heads}

  defp head_step({call, _, _, _}, tracked, heads, _args)
       when call in [:call_last, :call_ext_last],
       do: {drop_x(tracked), heads}

  defp head_step(instr, tracked, heads, _args),
    do: {MapSet.new(Instr.carry(instr, tracked)), heads}

  defp drop_x(tracked), do: MapSet.reject(tracked, &match?({:x, _}, &1))

  # A copy or projection of a tracked register is tracked; anything else
  # written into `dst`, a literal included, is not.
  defp track(tracked, src, dst) do
    if MapSet.member?(tracked, register(src)),
      do: MapSet.put(tracked, register(dst)),
      else: MapSet.delete(tracked, register(dst))
  end

  defp tracked?(operand, tracked), do: MapSet.member?(tracked, register(operand))

  # Process.monitor/1 takes the pid in x0; :erlang.monitor/2 takes the
  # type in x0 and the pid in x1.
  defp handle(facts, ctx, {Process, :monitor, 1}, data), do: monitor(facts, ctx, {:x, 0}, data)
  defp handle(facts, ctx, {:erlang, :monitor, 2}, data), do: monitor(facts, ctx, {:x, 1}, data)

  defp handle(facts, ctx, {Process, :demonitor, arity}, _data) when arity in [1, 2],
    do: demonitor(facts, ctx, arity)

  defp handle(facts, ctx, {:erlang, :demonitor, arity}, _data) when arity in [1, 2],
    do: demonitor(facts, ctx, arity)

  defp handle(facts, _ctx, _mfa, _data), do: facts

  # The target column: the monitored name when it is a literal, `"started_child"`
  # when the pid came back from a supervisor start (directly, or through a
  # local wrapper that performs one), else "dynamic".
  defp monitor(facts, ctx, pid_reg, module_data) do
    id = InstrId.mint(ctx.func_id, ctx.idx)

    target =
      if started_child?(ctx.instrs, ctx.idx, pid_reg, module_data),
        do: "started_child",
        else: resolve_atom(ctx.instrs, ctx.idx, pid_reg)

    facts = add_fact(facts, :monitor_call, [id, ctx.func_id, target])

    if ref_dropped?(cfg(module_data, ctx), ctx.instrs, ctx.idx + 1),
      do: add_fact(facts, :monitor_ref_dropped, [id, ctx.func_id]),
      else: facts
  end

  @x0 {:x, 0}

  @start_apis [
    {DynamicSupervisor, :start_child, 2},
    {Supervisor, :start_child, 2},
    {Task.Supervisor, :start_child, 2},
    {Task.Supervisor, :start_child, 3}
  ]

  # Whether the monitored pid is the result of a supervisor start: walk
  # back from the call to the write that produced the register (through
  # moves, tuple projections — `{:ok, pid} = ...` — and swaps) and see
  # whether it is a start API, or a local function that performs one.
  defp started_child?(instrs, idx, reg, module_data) do
    case pid_origin(instrs, idx, reg) do
      nil -> false
      mfa -> start_api?(mfa, module_data, [])
    end
  end

  # The call the pid came back from, through copies and tuple
  # projections (`{:ok, pid} = ...`), agreed on by every path to `idx`.
  defp pid_origin(instrs, idx, reg) do
    Resolve.trace(instrs, idx, reg, nil, fn
      {at, {:get_tuple_element, src, _index, _dst}}, follow -> follow.(at, src)
      {_at, {:call, _arity, {m, f, a}}}, _follow -> {m, f, a}
      {_at, {:call_ext, _arity, {:extfunc, m, f, a}}}, _follow -> {m, f, a}
      _writer, _follow -> nil
    end)
  end

  defp start_api?(mfa, _module_data, _seen) when mfa in @start_apis, do: true

  defp start_api?({mod, f, a}, %{module: mod, functions: functions} = module_data, seen) do
    if {f, a} in seen or length(seen) > 3 do
      false
    else
      seen = [{f, a} | seen]

      case Enum.find(functions, &match?({:function, ^f, ^a, _, _}, &1)) do
        nil ->
          false

        {:function, _, _, _, instrs} ->
          Enum.any?(instrs, fn instr ->
            case instr do
              {:call_ext, _, {:extfunc, m, g, b}} -> {m, g, b} in @start_apis
              {:call_ext_only, _, {:extfunc, m, g, b}} -> {m, g, b} in @start_apis
              {:call_ext_last, _, {:extfunc, m, g, b}, _} -> {m, g, b} in @start_apis
              {:call, _, {^mod, g, b}} -> start_api?({mod, g, b}, module_data, seen)
              {:call_only, _, {^mod, g, b}} -> start_api?({mod, g, b}, module_data, seen)
              {:call_last, _, {^mod, g, b}, _} -> start_api?({mod, g, b}, module_data, seen)
              _ -> false
            end
          end)
      end
    end
  end

  defp start_api?(_mfa, _module_data, _seen), do: false

  # Walks forward from the call along every path. Each instruction either
  # reads {x,0} (the ref is kept, and the answer is no), writes it without
  # reading (this path is done, the ref is gone on it), touches it not at
  # all (keep looking), or is something with x0 in a position whose
  # meaning is unknown — and that is "kept": a fact claiming a ref is gone
  # must be sure. Dropped when no path reaches a read. Without a graph
  # (a module whose facts could not be decoded) the ref counts as kept.
  defp ref_dropped?(nil, _instrs, _start), do: false

  defp ref_dropped?(fun, instrs, start) do
    result =
      Walk.explore(fun, instrs, [start],
        on_instr: fn
          {:func_info, _, _, _}, _idx ->
            :prune

          instr, _idx ->
            case classify(instr) do
              :reads -> {:halt, :kept}
              :unknown -> {:halt, :kept}
              :writes -> :prune
              :neutral -> :continue
            end
        end
      )

    match?({:done, _}, result)
  end

  # What an instruction does with the ref in {x,0}. `test_heap` with no
  # live registers and `deallocate` say what the compiler knows of x0's
  # liveness: dead at the first, about to be returned at the second.
  defp classify({:test_heap, _words, 0}), do: :writes
  defp classify({:deallocate, _}), do: :reads

  defp classify(instr) do
    cond do
      not Instr.known?(instr) -> :unknown
      @x0 in Instr.uses(instr) -> :reads
      Instr.defines?(instr, @x0) -> :writes
      true -> :neutral
    end
  end

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

  # ── A receive that takes its own monitor's :DOWN ─────────────────────

  defp emit_recv_down(facts, %{module: mod, functions: functions} = module_data) do
    Enum.reduce(functions, facts, fn {:function, name, arity, _entry, instrs}, acc ->
      func_id = InstrId.func_id(mod, name, arity)

      for {loop, monitor} <- awaited_monitors(instrs, fn -> cfg(module_data, name, arity) end),
          reduce: acc do
        acc ->
          add_fact(acc, :recv_down, [
            InstrId.mint(func_id, loop),
            func_id,
            InstrId.mint(func_id, monitor)
          ])
      end
    end)
  end

  # Each receive in the function that takes its own monitor's :DOWN, as
  # `{loop_rec, monitor}` indices.
  defp awaited_monitors(instrs, graph) do
    case for({{:loop_rec, _fail, _dst}, idx} <- Enum.with_index(instrs), do: idx) do
      [] ->
        []

      loops ->
        ctx = %{instrs: instrs, code: List.to_tuple(instrs), labels: labels(instrs)}

        for loop <- loops,
            {:ok, monitor} <- [awaited_monitor(ctx, loop, graph)],
            do: {loop, monitor}
    end
  end

  defp labels(instrs) do
    for {{:label, l}, i} <- Enum.with_index(instrs), into: %{}, do: {l, i}
  end

  # The monitor call whose :DOWN the receive at `loop` takes: the path
  # that message takes through the clause heads ends in `remove_message`
  # with the ref pinned to what that call returned, of a type whose
  # :DOWN says so, and nothing between the call and the receive
  # demonitors. The graph is built only for a receive that gets that far.
  defp awaited_monitor(ctx, loop, graph) do
    {:loop_rec, _fail, dst} = elem(ctx.code, loop)

    with {:taken, %{ref: {ref, compared_at}, type: type}} <-
           down_path(ctx, loop + 1, %{register(dst) => :msg}, %{ref: nil, type: nil}, 0),
         {at, monitor_type} <- ref_origin(ctx.instrs, compared_at, ref),
         true <- type in [nil, monitor_type],
         false <- demonitors_before?(graph.(), ctx.instrs, at, loop) do
      {:ok, at}
    else
      _ -> :none
    end
  end

  # Clause heads are a decision tree ending at `remove_message` (a clause
  # took the message) or `loop_rec_end` (none did); a :DOWN takes exactly
  # one path through it. The bound on steps is the tree's size; a head
  # never loops.
  @max_head_steps 200

  defp down_path(_ctx, _idx, _regs, _known, steps) when steps > @max_head_steps, do: :none

  defp down_path(ctx, idx, regs, known, steps) when idx < tuple_size(ctx.code) do
    case down_step(elem(ctx.code, idx), regs, known, idx) do
      {:next, regs, known} ->
        down_path(ctx, idx + 1, regs, known, steps + 1)

      {:jump, label, regs, known} ->
        case Map.fetch(ctx.labels, label) do
          {:ok, at} -> down_path(ctx, at, regs, known, steps + 1)
          :error -> :none
        end

      {:taken, known} ->
        {:taken, known}

      :none ->
        :none
    end
  end

  defp down_path(_ctx, _idx, _regs, _known, _steps), do: :none

  defp down_step({:label, _}, regs, known, _idx), do: {:next, regs, known}
  defp down_step({:line, _}, regs, known, _idx), do: {:next, regs, known}
  defp down_step({:recv_marker_clear, _}, regs, known, _idx), do: {:next, regs, known}
  defp down_step(:remove_message, _regs, known, _idx), do: {:taken, known}
  defp down_step({:jump, {:f, l}}, regs, known, _idx), do: {:jump, l, regs, known}

  defp down_step({:move, src, dst}, regs, known, _idx),
    do: {:next, carry(regs, value(src, regs), dst), known}

  defp down_step({:get_tuple_element, src, n, dst}, regs, known, _idx) do
    case value(src, regs) do
      :msg -> {:next, Map.put(regs, register(dst), {:elem, n}), known}
      _ -> {:next, Map.delete(regs, register(dst)), known}
    end
  end

  defp down_step({:test, :is_tuple, {:f, _}, [r]}, regs, known, _idx),
    do: if(value(r, regs) == :msg, do: {:next, regs, known}, else: :none)

  defp down_step({:test, :test_arity, {:f, l}, [r, n]}, regs, known, _idx) do
    cond do
      value(r, regs) != :msg -> :none
      n == 5 -> {:next, regs, known}
      true -> {:jump, l, regs, known}
    end
  end

  defp down_step({:test, :is_tagged_tuple, {:f, l}, [r, n, tag]}, regs, known, _idx) do
    cond do
      value(r, regs) != :msg -> :none
      n == 5 and tag == {:atom, :DOWN} -> {:next, regs, known}
      true -> {:jump, l, regs, known}
    end
  end

  defp down_step({:test, :is_atom, {:f, _}, [r]}, regs, known, _idx),
    do: if(value(r, regs) in [{:elem, 0}, {:elem, 2}], do: {:next, regs, known}, else: :none)

  defp down_step({:test, :is_reference, {:f, _}, [r]}, regs, known, _idx),
    do: if(value(r, regs) == {:elem, 1}, do: {:next, regs, known}, else: :none)

  defp down_step({:test, op, {:f, l}, [a, b]}, regs, known, idx)
       when op in [:is_eq_exact, :is_ne_exact] do
    # The compiler tests a pinned ref either way round: `is_ne_exact`
    # falls through to the next clause and jumps to the body on a match.
    case {op, equal(value(a, regs), value(b, regs), known, idx)} do
      {:is_eq_exact, {true, known}} -> {:next, regs, known}
      {:is_eq_exact, false} -> {:jump, l, regs, known}
      {:is_ne_exact, {true, known}} -> {:jump, l, regs, known}
      {:is_ne_exact, false} -> {:next, regs, known}
      {_op, :unknown} -> :none
    end
  end

  defp down_step({:select_tuple_arity, r, {:f, fail}, {:list, pairs}}, regs, known, _idx) do
    if value(r, regs) == :msg,
      do: {:jump, branch(pairs, 5, fail), regs, known},
      else: :none
  end

  defp down_step({:select_val, r, {:f, fail}, {:list, pairs}}, regs, known, _idx) do
    case value(r, regs) do
      {:elem, 0} -> {:jump, branch(pairs, {:atom, :DOWN}, fail), regs, known}
      # A select_val compares with atoms and numbers; the message is a tuple.
      :msg -> {:jump, fail, regs, known}
      _ -> :none
    end
  end

  # Between the last test and remove_message the compiler binds the
  # clause's variables and reserves heap: an instruction that neither
  # branches nor calls cannot refuse the message.
  defp down_step(instr, regs, known, _idx) do
    if Instr.known?(instr) and Instr.falls_through?(instr) and Instr.targets(instr) == [] and
         not Instr.call?(instr),
       do: {:next, Map.drop(regs, Instr.defs(instr)), known},
       else: :none
  end

  # The label a select branches to for `value`, or its fail label.
  defp branch([value, {:f, l} | _rest], value, _fail), do: l
  defp branch([_value, _label | rest], value, fail), do: branch(rest, value, fail)
  defp branch([], _value, fail), do: fail

  # Whether two operands are equal on the :DOWN, as `{true, known}` (with
  # what the answer had to assume), `false`, or `:unknown`. The ref
  # element equals the register it is compared with when that register
  # holds the monitor's ref, which `ref_origin/3` then has to show; a
  # message holding a ref equals no literal.
  defp equal(a, b, known, idx) do
    case down_equal(a, b, known, idx) do
      :unknown -> down_equal(b, a, known, idx)
      answer -> answer
    end
  end

  defp down_equal({:elem, 0}, {:lit, tag}, known, _idx), do: tag == :DOWN and {true, known}
  defp down_equal({:elem, 1}, {:lit, _}, _known, _idx), do: false

  defp down_equal({:elem, 1}, {:reg, reg}, %{ref: nil} = known, idx),
    do: {true, %{known | ref: {reg, idx}}}

  defp down_equal({:elem, 2}, {:lit, type}, %{type: seen} = known, _idx)
       when type in [:process, :port] and seen in [nil, type],
       do: {true, %{known | type: type}}

  defp down_equal({:elem, 2}, {:lit, type}, _known, _idx) when type in [:process, :port],
    do: :unknown

  defp down_equal({:elem, 2}, {:lit, _}, _known, _idx), do: false
  defp down_equal(:msg, {:lit, _}, _known, _idx), do: false
  defp down_equal(_a, _b, _known, _idx), do: :unknown

  # What an operand holds on the :DOWN's path: the message, one of its
  # elements, a literal, or a register the heads did not fill.
  defp value({:atom, a}, _regs), do: {:lit, a}
  defp value({:integer, i}, _regs), do: {:lit, i}
  defp value({:float, f}, _regs), do: {:lit, f}
  defp value({:literal, term}, _regs), do: {:lit, term}
  defp value(nil, _regs), do: {:lit, []}

  defp value(operand, regs) do
    reg = register(operand)
    Map.get(regs, reg, {:reg, reg})
  end

  defp carry(regs, {:reg, _}, dst), do: Map.delete(regs, register(dst))
  defp carry(regs, {:lit, _}, dst), do: Map.delete(regs, register(dst))
  defp carry(regs, held, dst), do: Map.put(regs, register(dst), held)

  # The monitor call every path's value of `ref` at `idx` came from, and
  # the type of what it monitors: only :process and :port monitors send a
  # :DOWN. A register a call writes is its result, x0: the compiler reads
  # no other x register after a call.
  defp ref_origin(instrs, idx, ref) do
    Resolve.trace(instrs, idx, ref, nil, fn
      {at, instr}, _follow when is_integer(at) -> monitor_type(instrs, at, instr)
      {:param, _}, _follow -> nil
    end)
  end

  defp monitor_type(instrs, at, {:call_ext, _, {:extfunc, :erlang, :monitor, arity}})
       when arity in [2, 3] do
    case Resolve.resolve_register(instrs, at, {:x, 0}) do
      {:ok, type} when type in [:process, :port] -> {at, type}
      _ -> nil
    end
  end

  defp monitor_type(_instrs, at, {:call_ext, _, {:extfunc, Process, :monitor, arity}})
       when arity in [1, 2],
       do: {at, :process}

  defp monitor_type(_instrs, _at, _instr), do: nil

  # Whether some path from the monitor call reaches a demonitor before it
  # reaches the receive. Without a graph the answer is yes: the fact must
  # be sure.
  defp demonitors_before?(nil, _instrs, _from, _loop), do: true

  defp demonitors_before?(fun, instrs, from, loop) do
    result =
      Walk.explore(fun, instrs, [from + 1],
        on_instr: fn
          _instr, ^loop -> :prune
          {:func_info, _, _, _}, _idx -> :prune
          instr, _idx -> if cancels_monitor?(instr), do: {:halt, :demonitor}, else: :continue
        end
      )

    match?({:halted, _}, result)
  end

  # Any demonitor, flushed or not: either cancels the :DOWN a later wait
  # would take.
  defp cancels_monitor?(instr) do
    case match_remote_call(instr) do
      {:ok, mod, :demonitor, arity} -> mod in [:erlang, Process] and arity in [1, 2]
      _ -> false
    end
  end

  defp flush_option(instrs, idx) do
    instrs
    |> Enum.take(idx)
    |> Enum.reverse()
    |> Enum.find_value("no_flush", fn
      {:move, {:literal, opts}, {:x, 1}} when is_list(opts) ->
        if :flush in list_elements(opts), do: "flush", else: "no_flush"

      {:move, _src, {:x, 1}} ->
        "no_flush"

      _ ->
        false
    end)
  end

  # ── A monitor the caller collects ────────────────────────────────────

  # A function that waits for any :DOWN (a receive for any monitor's, a
  # call to a collector) is walked from every call it makes; one whose
  # only waits are for a particular ref (a pinned receive, a flushing
  # demonitor) from the calls that ref comes from; the rest (nearly all)
  # cost one scan for their receives.
  defp emit_awaits_down_after(facts, %{module: mod, functions: functions} = module_data) do
    receives =
      Map.new(functions, fn {:function, name, arity, _entry, instrs} ->
        {{name, arity}, down_receives(instrs)}
      end)

    collectors = collectors(mod, functions, receives)

    Enum.reduce(functions, facts, fn {:function, name, arity, _entry, instrs}, acc ->
      ctx = %{
        mod: mod,
        instrs: instrs,
        receives: Map.fetch!(receives, {name, arity}),
        collectors: collectors
      }

      with [_ | _] = calls <- calls_to_walk(ctx),
           %Argus.Cfg.Function{} = fun <- cfg(module_data, name, arity) do
        func_id = InstrId.func_id(mod, name, arity)

        for call <- calls, collected_after?(fun, ctx, call), reduce: acc do
          acc -> add_fact(acc, :awaits_down_after, [func_id, InstrId.mint(func_id, call)])
        end
      else
        _ -> acc
      end
    end)
  end

  # The calls a wait in the function could follow, by instruction index.
  defp calls_to_walk(ctx) do
    indexed = Enum.with_index(ctx.instrs)

    waits_for_any? =
      Enum.any?(ctx.receives, fn {_idx, clauses} -> :any in clauses end) or
        Enum.any?(ctx.instrs, &collector_call?(&1, ctx))

    if waits_for_any? do
      for {instr, idx} <- indexed, Instr.call?(instr), do: idx
    else
      pinned =
        for {_idx, clauses} <- ctx.receives,
            {:pinned, at, reg} <- clauses,
            do: origin_call(ctx.instrs, at, reg)

      flushed =
        for {instr, idx} <- indexed,
            demonitor?(instr),
            flush_option(ctx.instrs, idx) == "flush",
            do: origin_call(ctx.instrs, idx, {:x, 0})

      (pinned ++ flushed) |> Enum.reject(&is_nil/1) |> Enum.uniq() |> Enum.sort()
    end
  end

  # The call whose result `reg` holds at `at`, directly or as an element
  # of it, on every path; nil when none or several.
  defp origin_call(instrs, at, reg) do
    Resolve.trace(instrs, at, register(reg), nil, fn
      {:param, _position}, _follow ->
        nil

      {writer, {:get_tuple_element, src, _index, _dst}}, follow ->
        follow.(writer, src)

      {writer, instr}, _follow ->
        if Instr.call?(instr), do: writer
    end)
  end

  # Every path from the call at `call` to the function's return passes a
  # wait for a :DOWN. A path that raises ends without returning, and one
  # that loops forever never returns either; neither is a return that
  # leaves the monitor behind.
  defp collected_after?(fun, ctx, call) do
    result =
      Walk.explore(fun, ctx.instrs, [call + 1],
        on_instr: fn instr, idx ->
          cond do
            waits_for_down?(instr, idx, call, ctx) -> :prune
            Instr.exits?(instr) and not raises?(instr) -> {:halt, :returns}
            true -> :continue
          end
        end
      )

    match?({:done, _}, result)
  end

  defp waits_for_down?({:loop_rec, _fail, _dst}, idx, call, ctx) do
    ctx.receives
    |> Map.get(idx, [])
    |> Enum.any?(fn
      :any -> true
      {:pinned, at, reg} -> origin_call(ctx.instrs, at, reg) == call
      :other -> false
    end)
  end

  defp waits_for_down?(instr, idx, call, ctx) do
    collector_call?(instr, ctx) or
      (demonitor?(instr) and flush_option(ctx.instrs, idx) == "flush" and
         origin_call(ctx.instrs, idx, {:x, 0}) == call)
  end

  defp collector_call?(instr, ctx) do
    case match_local_call(instr) do
      {:ok, mod, name, arity} -> mod == ctx.mod and MapSet.member?(ctx.collectors, {name, arity})
      :none -> false
    end
  end

  defp demonitor?(instr) do
    case match_remote_call(instr) do
      {:ok, mod, :demonitor, 2} -> mod in [:erlang, Process]
      _ -> false
    end
  end

  # A tail call that never returns: the path raises.
  @raising [:error, :exit, :throw, :raise, :nif_error]
  defp raises?(instr) do
    case match_remote_call(instr) do
      {:ok, :erlang, name, _arity} -> name in @raising
      _ -> false
    end
  end

  # The functions of the module that wait for any monitor's :DOWN in a
  # receive with no `after`, and those that call one, to a fixpoint.
  defp collectors(mod, functions, receives) do
    calls =
      Map.new(functions, fn {:function, name, arity, _entry, instrs} ->
        callees =
          for instr <- instrs,
              {:ok, ^mod, callee, callee_arity} <- [match_local_call(instr)],
              uniq: true,
              do: {callee, callee_arity}

        {{name, arity}, callees}
      end)

    waiting =
      for {key, receives} <- receives,
          Enum.any?(receives, fn {_idx, clauses} -> :any in clauses end),
          into: MapSet.new(),
          do: key

    close_collectors(waiting, calls)
  end

  defp close_collectors(set, calls) do
    grown =
      for {key, callees} <- calls,
          not MapSet.member?(set, key),
          Enum.any?(callees, &MapSet.member?(set, &1)),
          into: set,
          do: key

    if MapSet.size(grown) == MapSet.size(set), do: set, else: close_collectors(grown, calls)
  end

  # The receives with no `after`, by loop_rec index, each with its
  # {:DOWN, ...} clauses: `:any` when a clause does not compare the ref,
  # `{:pinned, at, reg}` when it compares it with `reg` at `at`, `:other`
  # when it compares it with anything else. A receive with an `after`
  # can end without the message, and is no wait.
  defp down_receives(instrs) do
    tuple = List.to_tuple(instrs)
    labels = for {{:label, l}, idx} <- Enum.with_index(instrs), into: %{}, do: {l, idx}

    for {{:loop_rec, {:f, fail}, _dst}, idx} <- Enum.with_index(instrs),
        blocking?(tuple, Map.get(labels, fail)),
        into: %{},
        do: {idx, down_clauses(tuple, idx, labels)}
  end

  # The empty-mailbox block of a receive with no `after` is a `wait`;
  # with one it is a `wait_timeout`, or `timeout` for `after 0`.
  defp blocking?(_tuple, nil), do: false

  defp blocking?(tuple, idx) when idx < tuple_size(tuple) do
    case elem(tuple, idx) do
      {:label, _} -> blocking?(tuple, idx + 1)
      {:line, _} -> blocking?(tuple, idx + 1)
      {:wait, _} -> true
      _ -> false
    end
  end

  defp blocking?(_tuple, _idx), do: false

  # Walks the clause heads of the receive at `idx` — each test's pass
  # edge falls through, its fail edge is the next clause — carrying the
  # registers that hold the message, its first element and its second,
  # and what the path has established of them. A path reaching
  # `remove_message` has matched a clause.
  defp down_clauses(tuple, idx, labels) do
    start = %{idx: idx + 1, msg: [{:x, 0}], tags: [], refs: [], tag: nil, ref: :any}
    walk_heads([start], tuple, labels, %{}, [])
  end

  defp walk_heads([], _tuple, _labels, _seen, acc), do: acc |> Enum.uniq() |> Enum.sort()

  defp walk_heads([state | rest], tuple, labels, seen, acc) do
    if state.idx >= tuple_size(tuple) or Map.has_key?(seen, state) do
      walk_heads(rest, tuple, labels, seen, acc)
    else
      seen = Map.put(seen, state, true)

      case head(elem(tuple, state.idx), state, labels) do
        {:matched, %{tag: :DOWN, ref: ref}} -> walk_heads(rest, tuple, labels, seen, [ref | acc])
        {:matched, _other} -> walk_heads(rest, tuple, labels, seen, acc)
        next -> walk_heads(next ++ rest, tuple, labels, seen, acc)
      end
    end
  end

  defp head(:remove_message, state, _labels), do: {:matched, state}
  defp head({:loop_rec_end, _}, _state, _labels), do: []
  defp head({:loop_rec, _, _}, _state, _labels), do: []
  defp head({:wait, _}, _state, _labels), do: []
  defp head({:wait_timeout, _, _}, _state, _labels), do: []
  defp head(:timeout, _state, _labels), do: []

  defp head(
         {:test, :is_tagged_tuple, {:f, fail}, [src, _size, {:atom, tag}]} = instr,
         state,
         labels
       ) do
    if held?(src, state.msg),
      do: pass(narrow(state, tag)) ++ goto(state, fail, labels),
      else: generic_head(instr, state, labels)
  end

  defp head({:test, :is_eq_exact, {:f, fail}, [a, b]} = instr, state, labels) do
    cond do
      tag = compared_atom(state.tags, a, b) ->
        pass(narrow(state, tag)) ++ goto(state, fail, labels)

      other = compared_with(state.refs, a, b) ->
        pass(%{state | ref: pinned(state.idx, other)}) ++ goto(state, fail, labels)

      true ->
        generic_head(instr, state, labels)
    end
  end

  defp head({:select_val, src, {:f, fail}, {:list, pairs}} = instr, state, labels) do
    cond do
      held?(src, state.tags) ->
        arms =
          pairs
          |> Enum.chunk_every(2)
          |> Enum.flat_map(fn
            [{:atom, tag}, {:f, l}] -> goto(narrow(state, tag), l, labels)
            [_value, {:f, l}] -> goto(state, l, labels)
            _malformed -> []
          end)

        arms ++ goto(state, fail, labels)

      held?(src, state.refs) ->
        generic_head(instr, %{state | ref: :other}, labels)

      true ->
        generic_head(instr, state, labels)
    end
  end

  defp head({:get_tuple_element, src, index, dst} = instr, state, _labels) do
    next = carry(state, instr)

    next =
      cond do
        not held?(src, state.msg) -> next
        index == 0 -> %{next | tags: Enum.sort([register(dst) | next.tags])}
        index == 1 -> %{next | refs: Enum.sort([register(dst) | next.refs])}
        true -> next
      end

    [%{next | idx: state.idx + 1}]
  end

  defp head(instr, state, labels), do: generic_head(instr, state, labels)

  # Any other instruction: both edges, with the tracked registers carried.
  # A comparison this does not read that involves the ref constrains it
  # (`:other`); a type test (`is_reference`) does not.
  defp generic_head(instr, state, labels) do
    state = if compares_ref?(instr, state.refs), do: %{state | ref: :other}, else: state
    next = carry(state, instr)
    fall = if Instr.falls_through?(instr), do: [%{next | idx: state.idx + 1}], else: []
    fall ++ Enum.flat_map(Instr.targets(instr), &goto(next, &1, labels))
  end

  @comparisons [:is_eq_exact, :is_ne_exact, :is_eq, :is_ne, :is_lt, :is_ge]

  defp compares_ref?({:test, op, _fail, args}, refs) when op in @comparisons and is_list(args),
    do: Enum.any?(args, &held?(&1, refs))

  defp compares_ref?(_instr, _refs), do: false

  defp pass(nil), do: []
  defp pass(state), do: [%{state | idx: state.idx + 1}]

  defp goto(nil, _label, _labels), do: []

  defp goto(state, label, labels) do
    case Map.fetch(labels, label) do
      {:ok, idx} -> [%{state | idx: idx}]
      :error -> []
    end
  end

  # The state once the message's tag is `tag`, or nil when the path
  # already established another: that edge cannot be taken.
  defp narrow(%{tag: nil} = state, tag), do: %{state | tag: tag}
  defp narrow(%{tag: tag} = state, tag), do: state
  defp narrow(_state, _tag), do: nil

  defp compared_atom(tags, a, b) do
    cond do
      held?(a, tags) -> atom_of(b)
      held?(b, tags) -> atom_of(a)
      true -> nil
    end
  end

  defp atom_of({:atom, atom}), do: atom
  defp atom_of(_operand), do: nil

  defp compared_with(refs, a, b) do
    cond do
      held?(a, refs) -> b
      held?(b, refs) -> a
      true -> nil
    end
  end

  defp pinned(at, operand) do
    case register(operand) do
      {kind, _} = reg when kind in [:x, :y] -> {:pinned, at, reg}
      _literal -> :other
    end
  end

  defp carry(state, instr) do
    %{
      state
      | msg: instr |> Instr.carry(state.msg) |> Enum.sort(),
        tags: instr |> Instr.carry(state.tags) |> Enum.sort(),
        refs: instr |> Instr.carry(state.refs) |> Enum.sort()
    }
  end

  defp held?(operand, regs), do: register(operand) in regs
end
