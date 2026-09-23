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
  - `matches_down(func)` — the function's clause heads (or a `case` on an
    argument, before any call) compare to `:DOWN`, so it is (part of) a
    :DOWN handler; unlike `callback_tag` this is emitted for every
    function, because a gen_statem funnels its :info events into private
    helpers that no callback name identifies

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

  alias Argus.Cfg.Walk
  alias Argus.Extractor.Helpers
  alias Argus.Instr
  alias Argus.InstrId

  import Argus.Extractor.Helpers,
    only: [
      add_fact: 3,
      cfg: 2,
      each_remote_call: 3,
      list_elements: 1,
      register: 1,
      resolve_atom: 3
    ]

  @impl true
  def relations,
    do: [
      :demonitor_call,
      :matches_down,
      :monitor_call,
      :monitor_ref_dropped
    ]

  @impl true
  def extract(%{module: mod, functions: functions} = module_data) do
    module_data
    |> each_remote_call(%{}, &handle(&1, &2, &3, module_data))
    |> emit_matches_down(mod, functions)
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
    Helpers.trace(instrs, idx, reg, nil, fn
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
end
