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
    is the monitored name when literal, else `"dynamic"`
  - `monitor_type(id, type)` — the kind of monitor taken at `id`:
    `process`, `port` or `time_offset` when literal (Process.monitor/1
    is `process`), else `dynamic`
  - `monitor_ref_dropped(id, func)` — the reference that monitor returned
    is discarded at the call site, so nothing can ever demonitor it
  - `monitor_answer(id, func, call, depth)` — the monitored pid is, on
    every path, what one of the calls the rows name answered, `depth`
    payloads down (`Argus.Extractor.Answers`: 0 the answer itself, 1 the
    pid of its `{:ok, pid}`); all or nothing, so a site with rows has one
    per call it may be. Any call: whether it answers a process it
    started, by itself or through the program's wrappers, is
    `clientlib/answers.dl`'s and the rules'. The pid of `{:error,
    {:already_started, pid}}` is an element of an element: a path that
    monitors it leaves the site without rows
  - `monitor_kept(id, func, kind, where, holds)` — where the monitoring
    function keeps the monitor's ref or the pid it monitors: a field of
    the state it returns (`field`, the key), an ETS call's argument
    (`table`, the call), or what it hands back (`returned`), each made of
    the ref (`holds` "ref"), or made whole of the pid alone ("pid")
    (`Argus.Extractor.StateFields`)
  - `awaits_child_exit(func)` — every start `func` makes is followed, on
    every path to its return, by a wait for the `:DOWN` of a monitor
    taken after the start (Livebook's `UniqueTask.run/2`): what it starts
    lives no longer than the call
  - `demonitor_call(id, func, flush)` — `flush` is `"flush"` or `"no_flush"`
  - `recv_down(id, func, monitor)` — a receive with a clause that takes
    the `:DOWN` of the monitor its function took at `monitor`, so it ends
    no later than the monitored process does
  - `matches_down(func)` — the function's clause heads (or a `case` on an
    argument, before any call) compare to `:DOWN`, so it is (part of) a
    :DOWN handler; unlike `callback_tag` this is emitted for every
    function, because a gen_statem funnels its :info events into private
    helpers that no callback name identifies
  - `monitor_released_after(func, call)` — every path in `func` from the
    call at `call` to its return takes a `:DOWN` or demonitors the ref the
    call returned (below)
  - `recv_signal(id, func, signal)` — a receive with a clause that takes
    the exit signal of the process a pinned register names, whatever its
    reason: a `:DOWN` (`"down"`) or an `:EXIT` (`"exit"`)
    (`Argus.Extractors.Monitor.ExitSignal`); a `:DOWN` only where no path
    from the function's entry to the receive demonitors
  - `recv_takes_down(id, func)` — a receive with a clause whose head fixes
    the tag to `:DOWN`: the function waits for a monitor's end
  - `recv_takes_exit(id, func)` — a receive with a clause that can take a
    trapped `{:EXIT, pid, reason}`: its head fixes the tag to `:EXIT`, or
    fixes none
  - `recv_flush(id, func, cancel)` — the receive runs only where the
    `cancel_timer` call at `cancel` returned `false`: the timer had fired,
    and its message is in the mailbox (`Argus.Extractors.Monitor.Flush`)

  Whether the ref is dropped is read from the instructions after the
  call, along every path: the ref arrives in `{x, 0}`, and it is dropped
  when on each path the next thing to happen to that register is a write
  that does not read it — a move of something else into it, a zero-arity
  call, a tuple built into it from other registers, a `test_heap`
  declaring no live registers. A read on any path, a return, and anything
  the scan does not understand count as kept, which is the direction
  that keeps the fact honest.

  ## A monitor released before the function returns

  A monitor is released when its `:DOWN` is taken or its ref is
  demonitored: `monitor_released_after(func, call)` names the calls
  after which every path to `func`'s return does one or the other. A
  demonitor releases the monitor with or without `[:flush]`; without it,
  a `:DOWN` the runtime had already sent stays queued, and is the
  mailbox's to take (the late message, not a monitor left live).

  A function may also take a monitor and return with it live on purpose:
  its caller goes on to wait for the `:DOWN`. OTP's old supervisor
  shutdown, copied into GenStage's ConsumerSupervisor and Horde's
  ProcessesSupervisor, monitors each child in `monitor_child/1`, looks
  once (`after 0`) for an `{:EXIT, ...}` already in the mailbox, and
  returns; its caller then blocks in `wait_children` until every child's
  `{:DOWN, ...}` has come. The calls such a release follows on every
  path are: a receive's `{:DOWN, ...}` clause that takes any monitor's
  (the ref is not compared), or the one whose ref the call returned; a
  `Process.demonitor/1,2` of that ref; or a call to a function
  of this module that takes one on every path to its return, or is a
  receive loop taking one on every path from its receive (a path that
  never enters the receive is the loop's end, taken on trust). The wait
  is the clause, never the receive: `receive do {:reply, x} -> ...;
  {:DOWN, ...} -> ... end` leaves with the monitor live on the reply
  path, and a timed receive does on its `after` (a grace period, then a
  kill and a wait, takes it on both). A callee that
  collects on some returns and returns an atom on every path that leaves
  its monitor live (the supervisor forks' `monitor_child/1`: `{error,
  Reason}` after the `:DOWN`, `ok` before it) has its collected side
  named by the caller's first test on the result: a tuple test's pass
  edge, or the fail edge of a comparison with that one atom. A path that
  raises is not asked: the wait was for a caller that is unwinding. A
  receive in a closure is seen where a library call runs the closure on
  every element of the refs (`Enum.each(refs, fn ref -> receive ...
  end)`, `@every_element`), the refs traced back through a reorder (the
  reverse a comprehension ends with) to the call that made them; any
  other closure's, and a wait in another module, are not, and leave the
  call without a row.

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
  alias Argus.Extractor.Answers
  alias Argus.Extractor.Dispatch
  alias Argus.Extractor.Resolve
  alias Argus.Extractor.ResultFate
  alias Argus.Extractor.StateFields
  alias Argus.Extractors.Monitor.ExitSignal
  alias Argus.Extractors.Monitor.Flush
  alias Argus.Extractors.TermFlow.Library
  alias Argus.Instr
  alias Argus.Instr.Reaching
  alias Argus.InstrId

  import Argus.Extractor.Helpers,
    only: [
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
      :awaits_child_exit,
      :demonitor_call,
      :matches_down,
      :monitor_call,
      :monitor_ref_dropped,
      :monitor_released_after,
      :monitor_answer,
      :monitor_kept,
      :monitor_type,
      :recv_down,
      :recv_flush,
      :recv_signal,
      :recv_takes_down,
      :recv_takes_exit
    ]

  @impl true
  def extract(%{module: mod, functions: functions} = module_data) do
    module_data
    |> each_remote_call(%{}, &handle(&1, &2, &3, module_data))
    |> emit_matches_down(mod, functions)
    |> emit_released_after(module_data)
    |> emit_recv_down(module_data)
    |> emit_recv_signal(module_data)
    |> emit_recv_takes_exit(mod, functions)
    |> emit_recv_takes_down(mod, functions)
    |> emit_recv_flush(module_data)
  end

  # ── A receive that flushes a timer that has fired ───────────────────

  # The graph is built only for a function that both cancels a timer and
  # receives.
  defp emit_recv_flush(facts, %{module: mod, functions: functions} = module_data) do
    Enum.reduce(functions, facts, fn {:function, name, arity, _entry, instrs}, acc ->
      if flush_candidate?(instrs) do
        func_id = InstrId.func_id(mod, name, arity)

        for {loop, cancel} <- Flush.guarded(instrs, cfg(module_data, name, arity)),
            reduce: acc do
          acc ->
            add_fact(acc, :recv_flush, [
              InstrId.mint(func_id, loop),
              func_id,
              InstrId.mint(func_id, cancel)
            ])
        end
      else
        acc
      end
    end)
  end

  defp flush_candidate?(instrs) do
    Enum.any?(instrs, &match?({:loop_rec, _, _}, &1)) and
      Enum.any?(instrs, fn instr ->
        match?({:ok, _, :cancel_timer, _}, match_remote_call(instr))
      end)
  end

  # ── A receive that ends when a particular process does ───────────────

  # A function that calls itself is a loop, and the `{:EXIT, parent, _}`
  # clause of a loop's receive ends the loop, not a wait for a reply: the
  # loop waits for its next message, from anyone. Its :DOWN clauses stay
  # (gen_server's multi_call waits for one reply or :DOWN per call of
  # itself). A loop through another function is not seen.
  #
  # A :DOWN is taken while the monitor is in place: a receive some path
  # from the function's entry reaches past a demonitor — of that ref or
  # any other, flushed or not — waits for a :DOWN the demonitor may have
  # cancelled, and is no row (`demonitors_before?`, as recv_down asks it
  # from the monitor). A demonitor after the wait (the reply branch of a
  # hand-rolled call) cancels nothing it waits for. The graph is built
  # only for a function that demonitors.
  defp emit_recv_signal(facts, %{module: mod, functions: functions} = module_data) do
    Enum.reduce(functions, facts, fn {:function, name, arity, _entry, instrs}, acc ->
      case for({{:loop_rec, _fail, _dst}, idx} <- Enum.with_index(instrs), do: idx) do
        [] ->
          acc

        receives ->
          func_id = InstrId.func_id(mod, name, arity)
          code = List.to_tuple(instrs)
          labels = labels(instrs)
          loops? = Enum.any?(instrs, &(match_local_call(&1) == {:ok, mod, name, arity}))
          demonitors? = Enum.any?(instrs, &cancels_monitor?/1)
          head = Enum.find_index(instrs, &match?({:func_info, _, _, _}, &1))

          for loop <- receives,
              signal <- ExitSignal.signals(code, labels, loop),
              not (loops? and signal == "exit"),
              not (signal == "down" and demonitors? and
                     demonitors_before?(cfg(module_data, name, arity), instrs, head, loop)),
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

  # Process.monitor/1 takes the pid in x0 and monitors a process;
  # :erlang.monitor/2 takes the type in x0 and the pid in x1.
  defp handle(facts, ctx, {Process, :monitor, 1}, data),
    do: monitor(facts, ctx, {:x, 0}, data) |> emit_monitor_type(ctx, "process")

  defp handle(facts, ctx, {:erlang, :monitor, 2}, data) do
    type =
      case resolve_atom(ctx.instrs, ctx.idx, {:x, 0}) do
        ":" <> atom -> atom
        _dynamic -> "dynamic"
      end

    facts |> monitor(ctx, {:x, 1}, data) |> emit_monitor_type(ctx, type)
  end

  defp handle(facts, ctx, {Process, :demonitor, arity}, _data) when arity in [1, 2],
    do: demonitor(facts, ctx, arity)

  defp handle(facts, ctx, {:erlang, :demonitor, arity}, _data) when arity in [1, 2],
    do: demonitor(facts, ctx, arity)

  defp handle(facts, _ctx, _mfa, _data), do: facts

  # What the monitor watches, and so what it sends: a process's or a
  # port's `:DOWN`, a clock service's `{:CHANGE, …}`.
  defp emit_monitor_type(facts, ctx, type),
    do: add_fact(facts, :monitor_type, [InstrId.mint(ctx.func_id, ctx.idx), type])

  # The target column: the monitored name when it is a literal, else
  # "dynamic". Whether the pid is one a start answered is the rules':
  # monitor_answer names the call it came from, and clientlib/answers.dl
  # follows that call through the program's wrappers to its origin.
  defp monitor(facts, ctx, pid_reg, module_data) do
    id = InstrId.mint(ctx.func_id, ctx.idx)
    target = resolve_atom(ctx.instrs, ctx.idx, pid_reg)
    facts = add_fact(facts, :monitor_call, [id, ctx.func_id, target])

    facts =
      ctx.instrs
      |> Answers.answered(ctx.idx, register(pid_reg))
      |> Enum.reduce(facts, fn {call, depth}, acc ->
        add_fact(acc, :monitor_answer, [
          id,
          ctx.func_id,
          InstrId.mint(ctx.func_id, call),
          to_string(depth)
        ])
      end)

    facts = emit_kept(facts, ctx, id, pid_reg)

    if ResultFate.lost?(module_data, ctx),
      do: add_fact(facts, :monitor_ref_dropped, [id, ctx.func_id]),
      else: facts
  end

  # ── Where the monitoring function keeps what the monitor is about ──
  #
  # The ref the monitor answered, or the pid it was handed: a field of the
  # state a return hands back whose value is made of the ref (whole or a
  # piece: `Map.put(subs, pid, ref)`, `{pid, ref}`), or made whole of the
  # pid (the same value, held in the field or a term the field is; not
  # another piece of the message the pid came in); an ETS call handed such
  # a value; and what the function hands back, which its callers keep
  # (`Argus.Extractor.StateFields`). A field the clause sets to anything
  # else is no record of the monitor, however near. Each row says what the
  # record holds: `ref` when it is made of the ref (the pid beside it or
  # not), `pid` when it holds the pid alone, so a rule can tell the record
  # a demonitor needs from one that only names the process.
  defp emit_kept(facts, ctx, id, pid_reg) do
    instrs = ctx.instrs
    pid = instrs |> Resolve.writers(ctx.idx, register(pid_reg)) |> MapSet.new()

    holds = fn made ->
      cond do
        StateFields.made_of?(made, ctx.idx) -> ["ref"]
        not MapSet.disjoint?(made.whole, pid) or not MapSet.disjoint?(made.arg, pid) -> ["pid"]
        true -> []
      end
    end

    # The returns and ETS calls the monitoring run reaches: a clause that
    # shares a destructuring with this one reads the same register for
    # another piece of its message.
    after_it = StateFields.reachable_from(instrs, ctx.idx)
    indexed = instrs |> Enum.with_index() |> Enum.filter(fn {_, i} -> i in after_it end)

    fields =
      for {:return, r} <- indexed,
          {key, _value, {at, operand}} <- StateFields.returned_fields(instrs, r),
          held <- holds.(StateFields.made_of(instrs, at, operand)),
          uniq: true,
          do: {"field", key, held}

    tables =
      for {instr, i} <- indexed,
          ets_call?(instr),
          held <- Enum.flat_map(Instr.uses(instr), &holds.(StateFields.made_of(instrs, i, &1))),
          uniq: true,
          do: {"table", InstrId.mint(ctx.func_id, i), held}

    returned = returned_pieces(instrs, after_it, holds)

    (fields ++ tables ++ returned)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.reduce(facts, fn {kind, where, held}, acc ->
      add_fact(acc, :monitor_kept, [id, ctx.func_id, kind, where, held])
    end)
  end

  # Where what the function hands back holds it: in element `i` of a
  # tuple a return builds (`{Nacc, Macc#{N => M}}`, global_group's sync
  # fold; `{:ok, ref}`), `"{i}"`, so a caller that keeps another element
  # keeps no record of it; anywhere else in what it hands back, `""`.
  defp returned_pieces(instrs, after_it, holds) do
    instrs
    |> Enum.with_index()
    |> Enum.filter(fn {_instr, i} -> i in after_it end)
    |> Enum.flat_map(fn
      {:return, r} ->
        instrs
        |> Resolve.writers(r, {:x, 0})
        |> Enum.flat_map(&pieces_at(instrs, r, &1, holds))

      {instr, i} ->
        if Instr.tail_call?(instr) do
          for held <- holds.(StateFields.returned_made_of(instrs, MapSet.new([i]))),
              do: {"returned", "", held}
        else
          []
        end
    end)
    |> Enum.uniq()
  end

  defp pieces_at(instrs, r, {:param, _k}, holds), do: whole_return(instrs, r, holds)

  defp pieces_at(instrs, r, w, holds) do
    case Reaching.at(instrs, w) do
      {:put_tuple2, _dst, {:list, elements}} ->
        for {element, i} <- Enum.with_index(elements),
            held <- holds.(StateFields.made_of(instrs, w, element)),
            do: {"returned", "{#{i}}", held}

      _ ->
        whole_return(instrs, r, holds)
    end
  end

  defp whole_return(instrs, r, holds) do
    for held <- holds.(StateFields.made_of(instrs, r, {:x, 0})), do: {"returned", "", held}
  end

  defp ets_call?(instr) do
    case match_remote_call(instr) do
      {:ok, :ets, _fun, _arity} -> true
      _ -> false
    end
  end

  # A call named like a start: `start*`, `spawn*`, or `open` (a client
  # library's connection, `:gun.open`).
  defp starts?(instr) do
    name =
      case {match_remote_call(instr), match_local_call(instr)} do
        {{:ok, _m, f, _a}, _} -> f
        {_, {:ok, _m, f, _a}} -> f
        _ -> nil
      end

    case name && Atom.to_string(name) do
      nil -> false
      "open" -> true
      text -> String.starts_with?(text, "start") or String.starts_with?(text, "spawn")
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

  # A function that waits for any :DOWN (a receive clause taking any
  # monitor's, a call to a collector) is walked from every call it makes;
  # one whose only releases are of a particular ref (a pinned clause, a
  # demonitor) from the calls that ref comes from; the rest (nearly all)
  # cost one scan for their receives.
  defp emit_released_after(facts, %{module: mod, functions: functions} = module_data) do
    takes =
      Map.new(functions, fn {:function, name, arity, _entry, instrs} ->
        {{name, arity}, down_takes(instrs)}
      end)

    collectors = collectors(module_data, takes)
    releasers = releasers(module_data, takes)
    tuple_collected = tuple_collected(module_data, takes, collectors)
    facts = emit_awaits_child_exit(facts, module_data, takes)

    Enum.reduce(functions, facts, fn {:function, name, arity, _entry, instrs}, acc ->
      entries = Map.fetch!(takes, {name, arity})

      ctx = %{
        mod: mod,
        instrs: instrs,
        takes: takes_at(entries),
        blocking_takes: takes_at(Enum.filter(entries, & &1.blocking)),
        collectors: collectors,
        releasers: releasers,
        tuple_collected: tuple_collected
      }

      with [_ | _] = calls <- calls_to_walk(ctx),
           %Argus.Cfg.Function{} = fun <- cfg(module_data, name, arity) do
        func_id = InstrId.func_id(mod, name, arity)

        for call <- calls, collected_after?(fun, ctx, call), reduce: acc do
          acc -> add_fact(acc, :monitor_released_after, [func_id, InstrId.mint(func_id, call)])
        end
      else
        _ -> acc
      end
    end)
  end

  # The calls a wait in the function could follow, by instruction index.
  defp calls_to_walk(ctx) do
    indexed = Enum.with_index(ctx.instrs)

    # The walks start from a wait with no `after` (or a collector): a
    # timed receive's :DOWN clause collects on its own path once a walk
    # runs, but starts none. A timed wait whose `after` raises (a
    # liveness bound) is the timed-wait class's own shape (encore's
    # madrigal seed), not a collection.
    waits_for_any? =
      Enum.any?(ctx.blocking_takes, fn {_at, ref} -> ref == :any end) or
        Enum.any?(ctx.instrs, &collector_call?(&1, ctx))

    if waits_for_any? do
      for {instr, idx} <- indexed, Instr.call?(instr), do: idx
    else
      pinned =
        for {_at, {:pinned, at, reg}} <- ctx.blocking_takes,
            do: ResultFate.origin_call(ctx.instrs, at, reg)

      cancelled =
        for {instr, idx} <- indexed,
            cancels_monitor?(instr),
            do: ResultFate.origin_call(ctx.instrs, idx, {:x, 0})

      handed =
        for {instr, idx} <- indexed,
            pos <- released_positions(instr, ctx, idx),
            do: ResultFate.origin_call(ctx.instrs, idx, {:x, pos})

      (pinned ++ cancelled ++ handed) |> Enum.reject(&is_nil/1) |> Enum.uniq() |> Enum.sort()
    end
  end

  # Library calls that run a fun on every element of a list, in the
  # calling process, none skipped: {list position, fun position}
  # (`TermFlow.Library`). A fun of the module that releases the monitor
  # its element names releases every monitor the list holds.
  @every_element Library.every_element()

  # Every path from the call at `call` to the function's return passes a
  # wait for a :DOWN. A path that raises ends without returning, and one
  # that loops forever never returns either; neither is a return that
  # leaves the monitor behind.
  defp collected_after?(fun, ctx, call) do
    collected_branch = collected_branch(ctx, call)

    result =
      Walk.explore(fun, ctx.instrs, [call + 1],
        on_instr: fn instr, idx ->
          cond do
            waits_for_down?(instr, idx, [call], ctx) -> :prune
            Instr.exits?(instr) and not raises?(instr) -> {:halt, :returns}
            true -> :continue
          end
        end,
        follow?: fn instr, kind -> collected_branch != {instr, kind} end
      )

    match?({:done, _}, result)
  end

  # ── A start whose caller waits for the child to exit ────────────────
  #
  # Livebook's UniqueTask.run/2 starts a child (or finds the running one),
  # monitors it and blocks for its :DOWN: the child lives no longer than
  # the call. Every start in the function (a call named start* or spawn*)
  # must be followed, on every path to the function's return, by a
  # receive clause that takes a :DOWN: any monitor's, or that of a monitor
  # the function takes after that start (its pinned ref). The receive
  # alone is not enough: a clause for the child's answer (`{:ready, ^pid}`)
  # leaves it with the child alive. A path that raises is not asked. A
  # start with no such take on some path (the child outlives the call
  # there) leaves the function without a row.
  defp emit_awaits_child_exit(facts, %{module: mod, functions: functions} = module_data, takes) do
    for {:function, name, arity, _entry, instrs} <- functions,
        starts = for({instr, idx} <- Enum.with_index(instrs), starts?(instr), do: idx),
        starts != [],
        down = takes_at(Map.fetch!(takes, {name, arity})),
        down != %{},
        %Argus.Cfg.Function{} = fun <- [cfg(module_data, name, arity)],
        Enum.all?(starts, &child_awaited?(fun, instrs, down, &1)),
        reduce: facts do
      acc -> add_fact(acc, :awaits_child_exit, [InstrId.func_id(mod, name, arity)])
    end
  end

  defp child_awaited?(fun, instrs, down, start) do
    result =
      Walk.explore(fun, instrs, [start + 1],
        on_instr: fn instr, idx ->
          cond do
            waits_after?(instr, idx, down, instrs, start) -> :prune
            Instr.exits?(instr) and not raises?(instr) -> {:halt, :returns}
            true -> :continue
          end
        end
      )

    match?({:done, _}, result)
  end

  defp waits_after?(:remove_message, idx, down, instrs, start) do
    case Map.fetch(down, idx) do
      {:ok, :any} ->
        true

      {:ok, {:pinned, at, reg}} ->
        case ResultFate.origin_call(instrs, at, reg) do
          nil -> false
          monitor -> monitor > start and monitor_call?(Enum.at(instrs, monitor))
        end

      _ ->
        false
    end
  end

  defp waits_after?(_instr, _idx, _down, _instrs, _start), do: false

  defp monitor_call?(instr),
    do: match_remote_call(instr) in [{:ok, :erlang, :monitor, 2}, {:ok, Process, :monitor, 1}]

  # ── A monitor its callee collected on the way back ──────────────────
  #
  # OTP's old supervisor, as rabbit's supervisor2 and brod's
  # brod_supervisor3 copy it: monitor_child/1 monitors, and if the
  # child's {'EXIT', ...} is already queued it waits there for the
  # :DOWN and returns {error, Reason}; otherwise it returns ok with the
  # monitor live. Its callers test the result: `is_tuple` sends the
  # collected case straight back, and only the ok side waits for the
  # :DOWN. So that side is the only one a wait must follow.
  #
  # A local function is tuple-collected when every return a path from
  # its monitor reaches without passing a wait for a :DOWN returns an
  # atom literal: a tuple it returns has waited. The first test on the
  # call's result then names a collected edge: the pass edge of a tuple
  # test (Erlang's `case monitor_child(Pid) of ok -> ...; {error, _} ->`),
  # or the fail edge of a comparison with the one atom it returns live
  # (Elixir's `case ... do :ok -> ...`). `{instr, edge}`, or nil.
  @tuple_tests [:is_tuple, :is_tagged_tuple, :test_arity]

  defp collected_branch(ctx, call) do
    with {:ok, mod, name, arity} <- match_local_call(Enum.at(ctx.instrs, call)),
         true <- mod == ctx.mod,
         {:ok, live} <- Map.fetch(ctx.tuple_collected, {name, arity}) do
      case Enum.at(ctx.instrs, call + 1) do
        {:test, op, _fail, [arg | _]} = test when op in @tuple_tests ->
          if register(arg) == {:x, 0}, do: {test, :branch_pass}

        {:test, :is_eq_exact, _fail, [arg, {:atom, atom}]} = test ->
          if register(arg) == {:x, 0} and live == [atom], do: {test, :branch_fail}

        _ ->
          nil
      end
    else
      _ -> nil
    end
  end

  # `%{{name, arity} => the atoms it returns with its monitor live}`.
  defp tuple_collected(%{module: mod, functions: functions} = module_data, takes, collectors) do
    for {:function, name, arity, _entry, instrs} <- functions,
        monitors = monitor_sites(instrs),
        monitors != [],
        %Argus.Cfg.Function{} = fun <- [cfg(module_data, name, arity)],
        ctx = %{
          mod: mod,
          instrs: instrs,
          takes: takes_at(Map.fetch!(takes, {name, arity})),
          collectors: collectors
        },
        {:ok, atoms} <- [live_return_atoms(fun, ctx, monitors)],
        into: %{},
        do: {{name, arity}, atoms}
  end

  defp monitor_sites(instrs) do
    for {instr, idx} <- Enum.with_index(instrs),
        match_remote_call(instr) in [{:ok, :erlang, :monitor, 2}, {:ok, Process, :monitor, 1}],
        do: idx
  end

  # The atoms every return reached from a monitor with the monitor live
  # returns, when each is an atom literal: `{:ok, sorted atoms}`, or
  # :error.
  defp live_return_atoms(fun, ctx, monitors) do
    returns =
      Walk.explore(fun, ctx.instrs, Enum.map(monitors, &(&1 + 1)),
        on_instr: fn instr, idx ->
          cond do
            waits_for_down?(instr, idx, monitors, ctx) -> :prune
            instr == :return -> :prune
            Instr.exits?(instr) and not raises?(instr) -> {:halt, :no}
            true -> :continue
          end
        end
      )

    with {:done, visited} <- returns,
         atoms =
           for(
             at <- visited,
             Enum.at(ctx.instrs, at) == :return,
             do: returned_atom(ctx.instrs, at)
           ),
         [_ | _] <- atoms,
         false <- nil in atoms do
      {:ok, atoms |> Enum.uniq() |> Enum.sort()}
    else
      _ -> :error
    end
  end

  defp returned_atom(instrs, idx) do
    Resolve.trace(instrs, idx, {:x, 0}, nil, fn
      {_at, {:move, {:atom, atom}, _dst}}, _follow -> atom
      _writer, _follow -> nil
    end)
  end

  # A wait for the :DOWN of the monitor one of `calls` took. It is the
  # clause of a receive that took a :DOWN (any monitor's, or the one
  # whose ref the call returned), not the receive: a clause for the
  # peer's answer leaves it with the monitor live. So is a demonitor of
  # that ref, flushed or not, and a call to a collector.
  defp waits_for_down?(:remove_message, idx, calls, ctx) do
    case Map.fetch(ctx.takes, idx) do
      {:ok, :any} -> true
      {:ok, {:pinned, at, reg}} -> ResultFate.origin_call(ctx.instrs, at, reg) in calls
      _ -> false
    end
  end

  defp waits_for_down?(instr, idx, calls, ctx) do
    collector_call?(instr, ctx) or
      (cancels_monitor?(instr) and ResultFate.origin_call(ctx.instrs, idx, {:x, 0}) in calls) or
      Enum.any?(
        released_positions(instr, ctx, idx),
        &(ResultFate.origin_call(ctx.instrs, idx, {:x, &1}) in calls)
      )
  end

  # The argument positions at which a local call hands a releaser the
  # ref it releases; [] for anything else.
  defp released_positions(instr, ctx, idx) do
    case match_local_call(instr) do
      {:ok, mod, name, arity} when mod == ctx.mod ->
        Map.get(Map.get(ctx, :releasers, %{}), {name, arity}, [])

      _ ->
        every_element_released(instr, ctx, idx)
    end
  end

  # `Enum.each(refs, fn ref -> receive do {:DOWN, ^ref, ...} -> ... end end)`:
  # the list position, when the fun the call runs on every element is a
  # closure of the module that releases its element (parameter 0).
  defp every_element_released(instr, ctx, idx) do
    with {:ok, mod, fun, arity} <- match_remote_call(instr),
         {:ok, {list, at}} <- Map.fetch(@every_element, {mod, fun, arity}),
         {:closure, {closure_mod, name, closure_arity}} when closure_mod == ctx.mod <-
           Resolve.fun_origin(ctx.instrs, idx, {:x, at}),
         true <- 0 in Map.get(Map.get(ctx, :releasers, %{}), {name, closure_arity}, []) do
      [list]
    else
      _ -> []
    end
  end

  # ── A function that releases the monitor it is handed ───────────────
  #
  # `%{{name, arity} => [position]}`: every path from the function's
  # entry to its return releases the monitor whose ref its parameter at
  # `position` holds: a receive clause takes that ref's :DOWN, a
  # demonitor cancels it, or a call hands it, at a position released
  # so, to a function of the module (the function itself included: a
  # wait loop that goes round again, taken on trust). A path that raises
  # is not asked. Finch's HTTP/2 pool waits for a response in a loop
  # that demonitors on every way out; a wait for the ref's :DOWN that
  # flushes it on the timeout releases it on both.
  defp releasers(%{functions: functions} = module_data, takes) do
    code =
      Map.new(functions, fn {:function, name, arity, _entry, instrs} ->
        {{name, arity}, instrs}
      end)

    candidates =
      for {:function, name, arity, _entry, instrs} <- functions,
          pos <- ref_params(instrs, Map.fetch!(takes, {name, arity})),
          into: MapSet.new(),
          do: {{name, arity}, pos}

    check = fn {key, pos}, set ->
      releases?(module_data, key, pos, Map.fetch!(code, key), Map.fetch!(takes, key), set)
    end

    candidates
    |> shrink_releasers(check)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

  defp shrink_releasers(set, check) do
    kept = MapSet.filter(set, &check.(&1, set))
    if MapSet.size(kept) == MapSet.size(set), do: set, else: shrink_releasers(kept, check)
  end

  # The parameters a function takes a pinned :DOWN of, or demonitors.
  defp ref_params(instrs, entries) do
    pinned =
      for %{ref: {:pinned, at, reg}} <- entries,
          pos = param_origin(instrs, at, reg),
          pos != nil,
          do: pos

    cancelled =
      for {instr, idx} <- Enum.with_index(instrs),
          cancels_monitor?(instr),
          pos = param_origin(instrs, idx, {:x, 0}),
          pos != nil,
          do: pos

    Enum.uniq(pinned ++ cancelled)
  end

  defp releases?(module_data, {name, arity}, pos, instrs, entries, set) do
    takes = takes_at(entries)
    mod = module_data.module

    on_instr = fn instr, idx ->
      cond do
        releases_param?(instr, idx, instrs, takes, pos) -> :prune
        hands_param?(instr, idx, instrs, pos, set, mod) -> :prune
        Instr.exits?(instr) and not raises?(instr) -> {:halt, :returns}
        true -> :continue
      end
    end

    case cfg(module_data, name, arity) do
      %Argus.Cfg.Function{} = fun ->
        match?(
          {:done, _},
          Walk.explore(fun, instrs, [Dispatch.entry_index(instrs)], on_instr: on_instr)
        )

      _ ->
        false
    end
  end

  defp releases_param?(:remove_message, idx, instrs, takes, pos) do
    case Map.get(takes, idx) do
      {:pinned, at, reg} -> param_origin(instrs, at, reg) == pos
      _ -> false
    end
  end

  defp releases_param?(instr, idx, instrs, _takes, pos),
    do: cancels_monitor?(instr) and param_origin(instrs, idx, {:x, 0}) == pos

  defp hands_param?(instr, idx, instrs, pos, set, mod) do
    case match_local_call(instr) do
      {:ok, ^mod, name, arity} ->
        Enum.any?(0..(arity - 1)//1, fn q ->
          MapSet.member?(set, {{name, arity}, q}) and param_origin(instrs, idx, {:x, q}) == pos
        end)

      _ ->
        false
    end
  end

  # The parameter `reg` holds at `at`, on every path; nil when anything
  # else.
  defp param_origin(instrs, at, reg) do
    Resolve.trace(instrs, at, register(reg), nil, fn
      {:param, position}, _follow -> position
      _writer, _follow -> nil
    end)
  end

  defp collector_call?(instr, ctx) do
    case match_local_call(instr) do
      {:ok, mod, name, arity} -> mod == ctx.mod and Map.has_key?(ctx.collectors, {name, arity})
      :none -> false
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

  # The functions of the module a call to which is a wait for any
  # monitor's :DOWN, as `%{{name, arity} => true}`: every path from the
  # function's entry to its return takes a :DOWN (a receive clause that
  # does not compare the ref) or calls another collector. Or it is a
  # receive loop — it calls itself, and holds a receive with no `after`
  # taking any :DOWN — and every path from that receive to the return
  # takes one or calls a collector: a path that never enters the receive
  # is the loop's end (wait_children's count reaching 0), taken on trust.
  # A receive whose other clause returns (the peer's answer, then a
  # return) is no wait: that path leaves the monitor live. The greatest
  # set that holds, so a loop's call to itself counts: from every
  # function that takes such a :DOWN or calls one that does, the ones
  # with a path past every wait are dropped until none is.
  defp collectors(%{module: mod, functions: functions} = module_data, takes) do
    calls =
      Map.new(functions, fn {:function, name, arity, _entry, instrs} ->
        callees =
          for instr <- instrs,
              {:ok, ^mod, callee, callee_arity} <- [match_local_call(instr)],
              uniq: true,
              do: {callee, callee_arity}

        {{name, arity}, callees}
      end)

    seeds =
      for {key, entries} <- takes,
          Enum.any?(entries, &(&1.ref == :any)),
          into: %{},
          do: {key, true}

    code =
      Map.new(functions, fn {:function, name, arity, _entry, instrs} ->
        {{name, arity}, instrs}
      end)

    check = fn {name, arity} = key, set ->
      collects?(module_data, key, Map.fetch!(code, key), Map.fetch!(takes, key), %{
        mod: mod,
        collectors: set,
        self: key,
        recursive: {name, arity} in Map.fetch!(calls, key)
      })
    end

    seeds |> close_collectors(calls) |> shrink_collectors(check)
  end

  defp close_collectors(set, calls) do
    grown =
      for {key, callees} <- calls,
          not Map.has_key?(set, key),
          Enum.any?(callees, &Map.has_key?(set, &1)),
          into: set,
          do: {key, true}

    if map_size(grown) == map_size(set), do: set, else: close_collectors(grown, calls)
  end

  defp shrink_collectors(set, check) do
    kept = for {key, true} <- set, check.(key, set), into: %{}, do: {key, true}
    if map_size(kept) == map_size(set), do: set, else: shrink_collectors(kept, check)
  end

  defp collects?(module_data, {name, arity}, instrs, entries, ctx) do
    takes = takes_at(entries)

    on_instr = fn instr, idx ->
      cond do
        Map.get(takes, idx) == :any -> :prune
        collector_call?(instr, ctx) -> :prune
        Instr.exits?(instr) and not raises?(instr) -> {:halt, :returns}
        true -> :continue
      end
    end

    loops = for %{blocking: true, ref: :any, loop: loop} <- entries, uniq: true, do: loop

    starts =
      if ctx.recursive and loops != [],
        do: loops,
        else: [Dispatch.entry_index(instrs)]

    case cfg(module_data, name, arity) do
      %Argus.Cfg.Function{} = fun ->
        match?({:done, _}, Walk.explore(fun, instrs, starts, on_instr: on_instr))

      _ ->
        false
    end
  end

  # ── A receive that can take a trapped exit ──────────────────────────
  #
  # A receive with a clause that can take `{:EXIT, pid, reason}`: its
  # head fixes the message's tag to :EXIT, or fixes none (a catch-all, a
  # variable, a test of another element). A clause whose head fixes
  # another tag, or matches an atom, cannot. The arity is not read: a
  # clause for `{:EXIT, pid}` counts, in the quiet direction.
  defp emit_recv_takes_exit(facts, mod, functions) do
    for {:function, name, arity, _entry, instrs} <- functions,
        loop <- exit_takers(instrs),
        reduce: facts do
      acc ->
        func_id = InstrId.func_id(mod, name, arity)
        add_fact(acc, :recv_takes_exit, [InstrId.mint(func_id, loop), func_id])
    end
  end

  # ── A receive that waits for a :DOWN ────────────────────────────────
  #
  # A receive with a clause whose head fixes the message's tag to :DOWN,
  # whatever it asks of the ref, the object or the reason: a function
  # with one waits for a monitor's end, in its own call. Unlike
  # recv_down and recv_signal, which ask whether the wait ends with the
  # monitored process, this asks only whether the monitor was taken for
  # a wait: Phoenix's LiveViewTest render_chunk/3 takes only a redirect's
  # :DOWN, on its error path, and returns on the others with the monitor
  # live.
  defp emit_recv_takes_down(facts, mod, functions) do
    for {:function, name, arity, _entry, instrs} <- functions,
        loop <- down_takers(instrs),
        reduce: facts do
      acc ->
        func_id = InstrId.func_id(mod, name, arity)
        add_fact(acc, :recv_takes_down, [InstrId.mint(func_id, loop), func_id])
    end
  end

  defp down_takers(instrs) do
    tuple = List.to_tuple(instrs)
    labels = for {{:label, l}, idx} <- Enum.with_index(instrs), into: %{}, do: {l, idx}

    for {{:loop_rec, _fail, _dst}, loop} <- Enum.with_index(instrs),
        start = %{idx: loop + 1, msg: [{:x, 0}], tags: [], refs: [], tag: nil, ref: :any},
        [start]
        |> take_heads(tuple, labels, %{}, [])
        |> Enum.any?(fn {_at, state} -> state.tag == :DOWN end),
        do: loop
  end

  defp exit_takers(instrs) do
    tuple = List.to_tuple(instrs)
    labels = for {{:label, l}, idx} <- Enum.with_index(instrs), into: %{}, do: {l, idx}

    for {{:loop_rec, _fail, _dst}, loop} <- Enum.with_index(instrs),
        start = %{idx: loop + 1, msg: [{:x, 0}], tags: [], refs: [], tag: nil, ref: :any},
        [start]
        |> take_heads(tuple, labels, %{}, [])
        |> Enum.any?(fn {_at, state} -> state.tag in [nil, :EXIT] end),
        do: loop
  end

  # ── The :DOWN clauses of a function's receives ──────────────────────
  #
  # Where a receive takes a :DOWN: the `remove_message` of each clause
  # whose pattern is `{:DOWN, ...}`, as `%{loop:, blocking:, at:, ref:}`
  # — the receive's `loop_rec`, whether it has no `after`, the
  # `remove_message`, and the ref: `:any` when the clause does not
  # compare it, `{:pinned, at, reg}` when it compares it with `reg` at
  # `at`, `:other` when with anything else. A `remove_message` some other
  # clause's path also reaches (the compiler shares identical clause
  # bodies) is not a take: that path took something else.
  #
  # A wait for a :DOWN is such a clause, never the receive: the other
  # clauses of `receive do {:reply, x} -> ...; {:DOWN, ...} -> ... end`
  # leave it with the monitor live. Each walk above prunes a path there.
  defp down_takes(instrs) do
    tuple = List.to_tuple(instrs)
    labels = for {{:label, l}, idx} <- Enum.with_index(instrs), into: %{}, do: {l, idx}

    for {{:loop_rec, {:f, fail}, _dst}, loop} <- Enum.with_index(instrs),
        blocking <- [blocking?(tuple, Map.get(labels, fail))],
        start = %{idx: loop + 1, msg: [{:x, 0}], tags: [], refs: [], tag: nil, ref: :any},
        {at, matched} <-
          [start]
          |> take_heads(tuple, labels, %{}, [])
          |> Enum.group_by(fn {at, _state} -> at end, fn {_at, state} -> state end),
        Enum.all?(matched, &(&1.tag == :DOWN)),
        do: %{loop: loop, blocking: blocking, at: at, ref: one_ref(matched)}
  end

  defp takes_at(entries), do: Map.new(entries, &{&1.at, &1.ref})

  defp one_ref(matched) do
    case matched |> Enum.map(& &1.ref) |> Enum.uniq() do
      [ref] -> ref
      _several -> :other
    end
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

  # Walks the clause heads of a receive — each test's pass edge falls
  # through, its fail edge is the next clause — carrying the registers
  # that hold the message, its first element and its second, and what the
  # path has established of them. A path reaching `remove_message` has
  # matched a clause: `{remove_message index, state}` for each.
  defp take_heads([], _tuple, _labels, _seen, acc), do: acc

  defp take_heads([state | rest], tuple, labels, seen, acc) do
    if state.idx >= tuple_size(tuple) or Map.has_key?(seen, state) do
      take_heads(rest, tuple, labels, seen, acc)
    else
      seen = Map.put(seen, state, true)

      case head(elem(tuple, state.idx), state, labels) do
        {:matched, matched} ->
          take_heads(rest, tuple, labels, seen, [{matched.idx, matched} | acc])

        next ->
          take_heads(next ++ rest, tuple, labels, seen, acc)
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

      atom = compared_atom(state.msg, a, b) ->
        pass(narrow(state, {:atom, atom})) ++ goto(state, fail, labels)

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

      held?(src, state.msg) ->
        arms =
          pairs
          |> Enum.chunk_every(2)
          |> Enum.flat_map(fn
            [{:atom, atom}, {:f, l}] -> goto(narrow(state, {:atom, atom}), l, labels)
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

  # The state once the message's tag is `tag` (`{:atom, a}`: the message
  # is the atom `a`, no tuple), or nil when the path already established
  # another: that edge cannot be taken.
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
