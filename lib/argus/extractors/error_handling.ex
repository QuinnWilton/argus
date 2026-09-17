defmodule Argus.Extractors.ErrorHandling do
  @moduledoc """
  Error handling extractor.

  Detects error handling patterns and anti-patterns in BEAM bytecode:
  bare rescues (catch-all without filtering or reraising), trap_exit
  without handlers, explicit exit calls, and ignored error results.

  ## Approach

  For bare rescue detection, walks forward from `try_start` handler labels.
  If the handler code contains no `test`/`select_val` filtering exception
  class and no `:erlang.raise/3` call, it's a bare rescue that silently
  swallows exceptions.

  ## Emitted facts

  - `bare_rescue(id, func)` — catch-all rescue without filtering or reraising
  - `trap_exit(func, mod)` — `Process.flag(:trap_exit, true)` call site
  - `exit_call(id, func, target)` — explicit `Process.exit/2` or `:erlang.exit/1,2`
  - `ignored_error_result(id, func, callee)` — call to known ok/error API where
    result is not pattern matched
  - `catch_total(id, func, class)` — some clause catches `class` without
    a pattern on the reason
  - `catch_tag(id, func, class, tag)` — an atom a clause catching `class`
    compares against (its reason pattern, or a `case` in its body);
    `rescue X` yields the struct name `X`
  - `catch_falls_through(id, func, tag)` — a `case` inside the handler,
    reached after comparing `tag`, has no clause for some value, so an
    unexpected reason is a CaseClauseError
  - `try_call(id, func, callee)` — a peer call (`GenServer.call`,
    `:gen_statem.call`, `:erpc.call`, ...) the `try` at `id` guards
  - `mailbox_writer(id, func, kind)` — a call after which something other
    than a peer's request lands in this process's mailbox: `task` (a
    Task.async reply, or an async_nolink collected in the same function),
    `task_nolink` (an async_nolink whose reply and :DOWN reach
    handle_info/2), `timer` (send_after / send_interval carrying a ref or
    a computed value), `timer_bare` (a timer whose message is a bare atom
    or literal, indistinguishable from an earlier instance), `cancel`
    (cancel_timer), `pubsub` (a subscription), `self` (the function sends
    to self()), `apply` (the function runs a caller-supplied function,
    which may do anything with this mailbox — the Flow producer of
    gen_stage#238 ran user code that called hackney)
  - `rpc_result(id, func, handling)` — how the result of an :rpc/:erpc
    call is treated: `badrpc`, `boolean`, `case`, `matched`, `returned`
    or `other`
  """

  @behaviour Argus.Extractor

  alias Argus.Extractor.Dispatch
  alias Argus.Extractors.ErrorHandling.CatchClauses
  alias Argus.InstrId
  alias Argus.Pipeline.Normalize

  import Argus.Extractor.Helpers,
    only: [
      add_fact: 3,
      arg_position: 3,
      call_result_origin: 3,
      map_field_of: 3,
      each_remote_call: 3,
      instructions_from_label: 2,
      match_remote_call: 1,
      resolve_atom: 3,
      resolve_register: 3,
      scan_functions: 4,
      track_dynamic: 5,
      track_imprecision: 5
    ]

  # Functions known to return {:ok, _} | {:error, _} whose result should
  # be checked. Only widely-used stdlib functions are included.
  @ok_error_apis MapSet.new([
                   {GenServer, :start_link, 2},
                   {GenServer, :start_link, 3},
                   {GenServer, :start, 2},
                   {GenServer, :start, 3},
                   {GenServer, :stop, 1},
                   {GenServer, :stop, 3},
                   {Supervisor, :start_link, 2},
                   {Supervisor, :start_link, 3},
                   {Agent, :start_link, 1},
                   {Agent, :start_link, 2},
                   {Agent, :start, 1},
                   {Agent, :start, 2},
                   {File, :open, 1},
                   {File, :open, 2},
                   {File, :read, 1},
                   {File, :write, 2},
                   {File, :write, 3},
                   {:gen_server, :start_link, 3},
                   {:gen_server, :start_link, 4},
                   {:gen_server, :start, 3},
                   {:gen_server, :start, 4},
                   {:gen_tcp, :connect, 3},
                   {:gen_tcp, :connect, 4},
                   {:gen_tcp, :listen, 2},
                   {:gen_udp, :open, 1},
                   {:gen_udp, :open, 2},
                   {:file, :open, 2},
                   {:file, :read_file, 1},
                   {:file, :write_file, 2}
                 ])

  @impl true
  def relations,
    do: [
      :bare_rescue,
      :catch_falls_through,
      :catch_tag,
      :catch_total,
      :exit_call,
      :ignored_error_result,
      :mailbox_writer,
      :recv_pattern,
      :returns_call,
      :rpc_result,
      :timer_arm,
      :timer_cancel,
      :timer_ref,
      :timer_store,
      :trap_exit,
      :try_call
    ]

  @impl true
  @spec extract(Argus.Extractor.module_data()) :: Argus.Pipeline.Emit.facts()
  def extract(module_data) do
    mod = module_data.module
    mod_str = inspect(mod)

    rescues =
      scan_functions(mod, module_data.functions, %{}, fn facts, ctx, instr ->
        facts
        |> maybe_bare_rescue(ctx, instr)
        |> maybe_catch_clauses(ctx, instr)
      end)

    rescues =
      rescues
      |> emit_self_sends(mod, module_data.functions)
      |> emit_timer_flows(mod, module_data.functions)

    each_remote_call(module_data, rescues, fn facts, ctx, mfa ->
      facts
      |> error_handling_call(mod_str, ctx, mfa)
      |> maybe_mailbox_writer(ctx, mfa)
      |> maybe_rpc_result(ctx, mfa)
    end)
  end

  @mailbox_writers %{
    {Task, :async, 1} => "task",
    {Task, :async, 3} => "task",
    {Task.Supervisor, :async, 2} => "task",
    {Task.Supervisor, :async, 4} => "task",
    {Task.Supervisor, :async_nolink, 2} => "task_nolink",
    {Task.Supervisor, :async_nolink, 4} => "task_nolink",
    # {"timer", msg, dest}: the registers holding the message and the
    # destination. Process.send_after(dest, msg, time) compiles to
    # :erlang.send_after(time, dest, msg); :timer.send_after/2 and
    # send_interval/2 target the caller.
    {Process, :send_after, 3} => {"timer", 1, 0},
    {Process, :send_after, 4} => {"timer", 1, 0},
    {:erlang, :send_after, 3} => {"timer", 2, 1},
    {:erlang, :send_after, 4} => {"timer", 2, 1},
    {:erlang, :start_timer, 3} => "timer",
    {:erlang, :start_timer, 4} => "timer",
    {:timer, :send_after, 2} => {"timer", 1, :self},
    {:timer, :send_after, 3} => {"timer", 2, 1},
    {:timer, :send_interval, 2} => {"timer", 1, :self},
    {:timer, :send_interval, 3} => {"timer", 2, 1},
    {Process, :cancel_timer, 1} => "cancel",
    {Process, :cancel_timer, 2} => "cancel",
    {:erlang, :cancel_timer, 1} => "cancel",
    {:erlang, :cancel_timer, 2} => "cancel",
    {:erlang, :cancel_timer, 3} => "cancel",
    {Phoenix.PubSub, :subscribe, 2} => "pubsub",
    {Phoenix.PubSub, :subscribe, 3} => "pubsub",
    {Registry, :register, 3} => "pubsub",
    {:pg, :join, 2} => "pubsub",
    {:pg, :join, 3} => "pubsub",
    {:pg2, :join, 2} => "pubsub",
    {:gen_event, :add_handler, 3} => "pubsub"
  }

  defp maybe_mailbox_writer(facts, ctx, mfa) do
    case Map.fetch(@mailbox_writers, mfa) do
      {:ok, {"timer", msg_reg, dest}} ->
        id = InstrId.mint(ctx.func_id, ctx.idx)
        {message, param, literal} = timer_message(ctx, msg_reg)
        kind = if message == "bare", do: "timer_bare", else: "timer"
        {flow, key} = ref_flow(ctx.instrs, ctx.idx)

        facts
        |> add_fact(:mailbox_writer, [id, ctx.func_id, kind])
        |> add_fact(:timer_arm, [
          id,
          ctx.func_id,
          timer_target(ctx, dest),
          message,
          to_string(param),
          literal
        ])
        |> add_fact(:timer_ref, [id, ctx.func_id, flow, key])

      {:ok, "cancel"} ->
        id = InstrId.mint(ctx.func_id, ctx.idx)
        {source, key, param} = cancel_source(ctx)

        facts
        |> add_fact(:mailbox_writer, [id, ctx.func_id, "cancel"])
        |> add_fact(:timer_cancel, [id, ctx.func_id, source, key, to_string(param)])

      {:ok, "task_nolink"} ->
        add_fact(facts, :mailbox_writer, [
          InstrId.mint(ctx.func_id, ctx.idx),
          ctx.func_id,
          if(collects_task?(ctx.instrs), do: "task", else: "task_nolink")
        ])

      {:ok, kind} ->
        add_fact(facts, :mailbox_writer, [InstrId.mint(ctx.func_id, ctx.idx), ctx.func_id, kind])

      :error ->
        facts
    end
  end

  # A timer whose message carries nothing the arming site made — a bare
  # atom, a literal tuple — cannot be told from an earlier instance of
  # itself: "bare". One that is a parameter of the arming function is
  # named by position, for a rule to look up at the callers (nebulex's
  # `start_timer(time, ref, event)`). One carrying a ref or a computed
  # value is "dynamic".
  defp timer_message(ctx, msg_reg) do
    case resolve_register(ctx.instrs, ctx.idx, {:x, msg_reg}) do
      {:ok, msg} ->
        if bare_message?(msg), do: {"bare", -1, inspect(msg)}, else: {"dynamic", -1, ""}

      _ ->
        case arg_position(ctx.instrs, ctx.idx, {:x, msg_reg}) do
          {:ok, n} -> {"param", n, ""}
          :no -> {"dynamic", -1, ""}
        end
    end
  end

  # Where the timer ref goes after the arming call: returned by the
  # function (a helper like `defp arm(ms), do: Process.send_after(...)`),
  # stored under a literal key of a map (`%{state | timer: ...}`,
  # `Map.put(state, :timer, ...)`), or somewhere the walk cannot follow.
  defp ref_flow(instrs, idx) do
    if tail_call?(Enum.at(instrs, idx)),
      do: {"returned", ""},
      else: ref_walk(Enum.drop(instrs, idx + 1), [{:x, 0}], instrs, idx + 1)
  end

  defp ref_walk([], _aliases, _instrs, _at), do: {"dynamic", ""}

  defp ref_walk([:return | _], aliases, _instrs, _at),
    do: if({:x, 0} in aliases, do: {"returned", ""}, else: {"dynamic", ""})

  defp ref_walk([{:move, src, dst} | rest], aliases, instrs, at),
    do: ref_walk(rest, retarget(aliases, src, dst), instrs, at + 1)

  defp ref_walk([{put_map, _f, _src, dst, _live, {:list, pairs}} | rest], aliases, instrs, at)
       when put_map in [:put_map_assoc, :put_map_exact] do
    case stored_key(pairs, aliases) do
      {:ok, key} -> {"stored", key}
      :none -> ref_walk(rest, List.delete(aliases, reg_of(dst)), instrs, at + 1)
    end
  end

  # Map.put(map, key, value) compiles to :maps.put(key, value, map).
  defp ref_walk([{:call_ext, 3, {:extfunc, :maps, :put, 3}} | _rest], aliases, instrs, at) do
    with true <- {:x, 1} in aliases,
         {:ok, key} when is_atom(key) <- resolve_register(instrs, at, {:x, 0}) do
      {"stored", inspect(key)}
    else
      _ -> {"dynamic", ""}
    end
  end

  defp ref_walk([{call, arity, _} | _], aliases, _instrs, _at)
       when call in [:call, :call_ext, :call_only, :call_ext_only] do
    if Enum.any?(0..(arity - 1)//1, &({:x, &1} in aliases)),
      do: {"dynamic", ""},
      else: {"dynamic", ""}
  end

  defp ref_walk([{:label, _} | _], _aliases, _instrs, _at), do: {"dynamic", ""}

  defp ref_walk([instr | rest], aliases, instrs, at) do
    case aliased_write(instr, aliases) do
      nil -> ref_walk(rest, aliases, instrs, at + 1)
      dst -> ref_walk(rest, List.delete(aliases, dst), instrs, at + 1)
    end
  end

  # The register an instruction writes, when that register is an alias:
  # the dst operand is last for every register-writing shape but the
  # maps and swaps handled above.
  defp aliased_write(instr, aliases) when is_tuple(instr) and tuple_size(instr) > 1 do
    case reg_of(elem(instr, tuple_size(instr) - 1)) do
      nil -> nil
      r -> if r in aliases, do: r, else: nil
    end
  end

  defp aliased_write(_instr, _aliases), do: nil

  defp stored_key(pairs, aliases) do
    pairs
    |> Enum.chunk_every(2)
    |> Enum.find_value(:none, fn
      [{:atom, key}, val] -> if alias?(val, aliases), do: {:ok, inspect(key)}, else: nil
      [{:literal, key}, val] -> if alias?(val, aliases), do: {:ok, inspect(key)}, else: nil
      _ -> nil
    end)
  end

  # Where the cancelled ref came from: a map field read in this function
  # (`state.timer`, or a `%{timer: ref}` head), a parameter (nebulex's
  # `start_timer(time, ref, event)`), or unknown.
  defp cancel_source(ctx) do
    case map_field_of(ctx.instrs, ctx.idx, {:x, 0}) do
      {:ok, key} ->
        {"field", key, -1}

      :dynamic ->
        case arg_position(ctx.instrs, ctx.idx, {:x, 0}) do
          {:ok, n} -> {"param", "", n}
          :no -> {"dynamic", "", -1}
        end
    end
  end

  # Per function: which map keys receive a call's result (timer_store),
  # which callee's result the function returns (returns_call), and what
  # each receive matches (recv_pattern).
  defp emit_timer_flows(facts, mod, functions) do
    Enum.reduce(functions, facts, fn {:function, name, arity, _entry, instrs}, acc ->
      if generated?(name) do
        acc
      else
        func_id = InstrId.func_id(mod, name, arity)

        acc
        |> emit_stores(mod, func_id, instrs)
        |> emit_returns(mod, func_id, instrs)
        |> emit_recv_patterns(func_id, instrs)
      end
    end)
  end

  # The compiler's own functions (__info__/1, module_info, -inlined-...)
  # never hold a timer.
  defp generated?(name) when name in [:__info__, :module_info, :__struct__], do: true
  defp generated?(name), do: String.starts_with?(Atom.to_string(name), "-")

  defp emit_stores(facts, mod, func_id, instrs) do
    instrs
    |> Enum.with_index()
    |> Enum.reduce(facts, fn
      {{put_map, _f, _src, _dst, _live, {:list, pairs}}, idx}, acc
      when put_map in [:put_map_assoc, :put_map_exact] ->
        pairs
        |> Enum.chunk_every(2)
        |> Enum.reduce(acc, fn
          [{:atom, key}, val], inner -> emit_store(inner, mod, func_id, instrs, idx, key, val)
          _, inner -> inner
        end)

      {{:call_ext, 3, {:extfunc, :maps, :put, 3}}, idx}, acc ->
        case resolve_register(instrs, idx, {:x, 0}) do
          {:ok, key} when is_atom(key) -> emit_store(acc, mod, func_id, instrs, idx, key, {:x, 1})
          _ -> acc
        end

      _, acc ->
        acc
    end)
  end

  defp emit_store(facts, mod, func_id, instrs, idx, key, val) do
    with r when r != nil <- reg_of(val),
         {:ok, {m, f, a}, _origin} <- call_result_origin(instrs, idx, r) do
      callee = InstrId.func_id(if(m == :local, do: mod, else: m), f, a)
      add_fact(facts, :timer_store, [func_id, inspect(key), callee])
    else
      _ -> facts
    end
  end

  defp emit_returns(facts, mod, func_id, instrs) do
    instrs
    |> Enum.with_index()
    |> Enum.reduce(facts, fn {instr, idx}, acc ->
      case returned_callee(instr, Enum.at(instrs, idx + 1), mod) do
        {:ok, callee} ->
          if String.contains?(callee, ":-"),
            do: acc,
            else: add_fact(acc, :returns_call, [func_id, callee])

        :none ->
          acc
      end
    end)
  end

  # Only calls into this module: the chain a ref takes through arming
  # helpers and default-argument wrappers. A remote callee's result is
  # already described at its own site (timer_ref).
  defp returned_callee({:call_only, _, {mod, f, a}}, _next, mod),
    do: {:ok, InstrId.func_id(mod, f, a)}

  defp returned_callee({:call_last, _, {mod, f, a}, _}, _next, mod),
    do: {:ok, InstrId.func_id(mod, f, a)}

  defp returned_callee({:call, _, {mod, f, a}}, :return, mod),
    do: {:ok, InstrId.func_id(mod, f, a)}

  defp returned_callee(_instr, _next, _mod), do: :none

  # What each receive in the function matches: a literal atom per
  # clause, or "any" for a clause whose pattern is not an atom (a tuple,
  # a wildcard, a guard on the message). Clause heads are found by
  # following each test's failure label from the loop_rec; a body
  # reached without a test on the message is a catch-all.
  defp emit_recv_patterns(facts, func_id, instrs) do
    labels = for {{:label, l}, i} <- Enum.with_index(instrs), into: %{}, do: {l, i}

    instrs
    |> Enum.with_index()
    |> Enum.reduce(facts, fn
      {{:loop_rec, _f, _dst}, idx}, acc ->
        instrs
        |> recv_heads(idx + 1, labels, [])
        |> Enum.uniq()
        |> Enum.reduce(acc, fn m, inner ->
          add_fact(inner, :recv_pattern, [InstrId.mint(func_id, idx), func_id, m])
        end)

      _, acc ->
        acc
    end)
  end

  defp recv_heads(instrs, idx, labels, seen) do
    if idx in seen or idx >= length(instrs) do
      []
    else
      recv_head(Enum.at(instrs, idx), instrs, idx, labels, [idx | seen])
    end
  end

  defp recv_head({:label, _}, instrs, idx, labels, seen),
    do: recv_heads(instrs, idx + 1, labels, seen)

  defp recv_head({:loop_rec_end, _}, _instrs, _idx, _labels, _seen), do: []
  defp recv_head({:wait, _}, _instrs, _idx, _labels, _seen), do: []
  defp recv_head({:wait_timeout, _, _}, _instrs, _idx, _labels, _seen), do: []

  defp recv_head({:test, :is_eq_exact, {:f, l}, [a, b]}, instrs, _idx, labels, seen) do
    case {reg_of(a), reg_of(b)} do
      {{:x, 0}, _} -> [pattern_of(b) | recv_fail(instrs, l, labels, seen)]
      {_, {:x, 0}} -> [pattern_of(a) | recv_fail(instrs, l, labels, seen)]
      _ -> recv_fail(instrs, l, labels, seen)
    end
  end

  defp recv_head({:select_val, src, {:f, l}, {:list, entries}}, instrs, _idx, labels, seen) do
    if reg_of(src) == {:x, 0},
      do: for({:atom, a} <- entries, do: inspect(a)) ++ recv_fail(instrs, l, labels, seen),
      else: recv_fail(instrs, l, labels, seen)
  end

  defp recv_head({:test, _op, {:f, l}, args}, instrs, _idx, labels, seen) when is_list(args) do
    if Enum.any?(args, &(reg_of(&1) == {:x, 0})),
      do: ["any" | recv_fail(instrs, l, labels, seen)],
      else: recv_fail(instrs, l, labels, seen)
  end

  defp recv_head({:test, _op, {:f, l}, src, _fields}, instrs, _idx, labels, seen) do
    if reg_of(src) == {:x, 0},
      do: ["any" | recv_fail(instrs, l, labels, seen)],
      else: recv_fail(instrs, l, labels, seen)
  end

  defp recv_head({:select_tuple_arity, _src, {:f, l}, _}, instrs, _idx, labels, seen),
    do: ["any" | recv_fail(instrs, l, labels, seen)]

  defp recv_head(_body, _instrs, _idx, _labels, _seen), do: ["any"]

  defp recv_fail(instrs, label, labels, seen) do
    case Map.fetch(labels, label) do
      {:ok, idx} -> recv_heads(instrs, idx, labels, seen)
      :error -> []
    end
  end

  defp pattern_of({:atom, a}), do: inspect(a)
  defp pattern_of(_other), do: "any"

  defp timer_target(_ctx, :self), do: "self"

  defp timer_target(ctx, dest_reg) do
    preceding = ctx.instrs |> Enum.take(ctx.idx) |> Enum.reverse()
    if self_origin?(preceding, {:x, dest_reg}), do: "self", else: "other"
  end

  # Whether `reg` holds the result of a `self()` call, following moves.
  # A call clobbers every x register, and any other instruction that
  # names the register is taken to write it.
  defp self_origin?([], _reg), do: false
  defp self_origin?([{:bif, :self, _, [], reg} | _], reg), do: true

  defp self_origin?([{:move, {kind, _} = src, reg} | rest], reg) when kind in [:x, :y],
    do: self_origin?(rest, src)

  defp self_origin?([{:move, _, reg} | _], reg), do: false

  defp self_origin?([instr | rest], reg) do
    cond do
      call_instr?(instr) and match?({:x, _}, reg) -> false
      reg in Tuple.to_list(instr) -> false
      true -> self_origin?(rest, reg)
    end
  end

  defp call_instr?(instr) when is_tuple(instr) and tuple_size(instr) > 0 do
    op = elem(instr, 0)

    op in [
      :call,
      :call_ext,
      :call_fun,
      :call_fun2,
      :apply,
      :call_only,
      :call_last,
      :call_ext_only,
      :call_ext_last,
      :apply_last,
      :return
    ]
  end

  defp call_instr?(instr), do: instr == :return

  # `:dynamic` is the resolver's placeholder for a value it could not
  # follow — a ref, a counter — and that is what makes a message safe.
  defp bare_message?(:dynamic), do: false
  defp bare_message?(msg) when is_atom(msg) or is_binary(msg) or is_number(msg), do: true

  defp bare_message?(msg) when is_tuple(msg),
    do: msg |> Tuple.to_list() |> Enum.all?(&bare_message?/1)

  defp bare_message?(msg) when is_list(msg), do: Enum.all?(msg, &bare_message?/1)
  defp bare_message?(_msg), do: false

  # An async_nolink task collected in the same function (await, yield,
  # shutdown, ignore) leaves nothing for handle_info/2.
  @task_collectors [
    {Task, :await, 1},
    {Task, :await, 2},
    {Task, :yield, 1},
    {Task, :yield, 2},
    {Task, :yield_many, 1},
    {Task, :yield_many, 2},
    {Task, :shutdown, 1},
    {Task, :shutdown, 2},
    {Task, :ignore, 1},
    {Task, :await_many, 1},
    {Task, :await_many, 2}
  ]

  defp collects_task?(instrs) do
    Enum.any?(instrs, fn instr ->
      case match_remote_call(instr) do
        {:ok, m, f, a} -> {m, f, a} in @task_collectors
        _ -> false
      end
    end)
  end

  # ── RPC results ────────────────────────────────────────────────────

  @rpc_calls [
    {:rpc, :call, 4},
    {:rpc, :call, 5},
    {:rpc, :block_call, 4},
    {:rpc, :block_call, 5},
    {:rpc, :multicall, 2},
    {:rpc, :multicall, 3},
    {:rpc, :multicall, 4},
    {:rpc, :multicall, 5},
    {:erpc, :call, 4},
    {:erpc, :call, 5}
  ]

  # How the function treats the result of an rpc: `badrpc` — it compares
  # something to :badrpc somewhere; `boolean` — the result is tested
  # against true/false/nil (an `&&`, an `if`), where a {:badrpc, _} tuple
  # is truthy; `case` — it is matched by shape in a function that has a
  # clause-less exit (case_end/badmatch), so {:badrpc, _} raises;
  # `matched` — matched with a wildcard somewhere; `returned` — the
  # function's own result (a predicate ending in `?` makes it a boolean
  # for its callers: `member?(n) && :rpc.call(...)`); `other` — stored
  # or passed on.
  defp maybe_rpc_result(facts, ctx, mfa) do
    if mfa in @rpc_calls do
      handling = rpc_handling(ctx.instrs, ctx.idx)
      add_fact(facts, :rpc_result, [InstrId.mint(ctx.func_id, ctx.idx), ctx.func_id, handling])
    else
      facts
    end
  end

  defp rpc_handling(instrs, idx) do
    cond do
      :badrpc in Dispatch.compared_atoms(instrs, :any) -> "badrpc"
      tail_call?(Enum.at(instrs, idx)) -> "returned"
      true -> result_use(Enum.drop(instrs, idx + 1), [{:x, 0}], instrs)
    end
  end

  @booleans [{:atom, true}, {:atom, false}, {:atom, nil}]

  # Follow the registers holding the rpc result (`aliases`, a list: a
  # MapSet is opaque to dialyzer) until something examines or consumes
  # it. One clause per instruction shape.
  defp result_use([], _aliases, _instrs), do: "other"

  defp result_use([{:test, _op, _f, [a, b]} | rest], aliases, instrs) do
    cond do
      boolean_test?(a, b, aliases) -> "boolean"
      alias?(a, aliases) or alias?(b, aliases) -> shape_use(instrs)
      true -> result_use(rest, aliases, instrs)
    end
  end

  defp result_use([{:test, _op, _f, args} | rest], aliases, instrs) when is_list(args),
    do: use_if_aliased(Enum.any?(args, &alias?(&1, aliases)), rest, aliases, instrs)

  defp result_use([{:test, _op, _f, src, _fields} | rest], aliases, instrs),
    do: use_if_aliased(alias?(src, aliases), rest, aliases, instrs)

  defp result_use([{op, src, _f, _list} | rest], aliases, instrs)
       when op in [:select_val, :select_tuple_arity],
       do: use_if_aliased(alias?(src, aliases), rest, aliases, instrs)

  defp result_use([{:move, src, dst} | rest], aliases, instrs),
    do: result_use(rest, retarget(aliases, src, dst), instrs)

  defp result_use([{:get_tuple_element, src, _i, dst} | rest], aliases, instrs),
    do: result_use(rest, retarget(aliases, src, dst), instrs)

  defp result_use([:return | _], aliases, _instrs),
    do: if({:x, 0} in aliases, do: "returned", else: "other")

  defp result_use([{call, arity, _} | rest], aliases, instrs)
       when call in [:call, :call_ext, :call_only, :call_ext_only] do
    if Enum.any?(0..(arity - 1)//1, &({:x, &1} in aliases)),
      do: "other",
      else: result_use(rest, Enum.reject(aliases, &match?({:x, _}, &1)), instrs)
  end

  defp result_use([{call, _arity, _, _} | _], _aliases, _instrs)
       when call in [:call_last, :call_ext_last],
       do: "other"

  defp result_use([{:label, _} | _], _aliases, _instrs), do: "other"
  defp result_use([_ | rest], aliases, instrs), do: result_use(rest, aliases, instrs)

  defp use_if_aliased(true, _rest, _aliases, instrs), do: shape_use(instrs)
  defp use_if_aliased(false, rest, aliases, instrs), do: result_use(rest, aliases, instrs)

  defp boolean_test?(a, b, aliases),
    do: (alias?(a, aliases) and b in @booleans) or (alias?(b, aliases) and a in @booleans)

  defp shape_use(instrs) do
    if Enum.any?(instrs, &(match?({:case_end, _}, &1) or match?({:badmatch, _}, &1))),
      do: "case",
      else: "matched"
  end

  defp retarget(aliases, src, dst) do
    if alias?(src, aliases),
      do: Enum.uniq([reg_of(dst) | aliases]),
      else: List.delete(aliases, reg_of(dst))
  end

  defp alias?(operand, aliases) do
    case reg_of(operand) do
      nil -> false
      r -> r in aliases
    end
  end

  defp reg_of({:tr, r, _}), do: reg_of(r)
  defp reg_of({:x, _} = r), do: r
  defp reg_of({:y, _} = r), do: r
  defp reg_of(_), do: nil

  # A function that both takes its own pid (`self()`) and sends: a
  # message it posts to itself, the shape a start-up kick or a restart
  # loop re-sends (cachex#314). The pairing is per function, not per
  # send — a register walk would be needed to tie the two, and a
  # function that does both is the shape either way.
  defp emit_self_sends(facts, mod, functions) do
    Enum.reduce(functions, facts, fn {:function, name, arity, _entry, instrs}, acc ->
      func_id = InstrId.func_id(mod, name, arity)
      self? = Enum.any?(instrs, &match?({:bif, :self, _, [], _}, &1))
      {send?, idx} = first_send(instrs)

      acc =
        if self? and send?,
          do: add_fact(acc, :mailbox_writer, [InstrId.mint(func_id, idx), func_id, "self"]),
          else: acc

      case Enum.find_index(instrs, &applies?/1) do
        nil -> acc
        i -> add_fact(acc, :mailbox_writer, [InstrId.mint(func_id, i), func_id, "apply"])
      end
    end)
  end

  # A call through a closure or `apply`: code this module does not own
  # runs in this process.
  defp applies?({:call_fun, _}), do: true
  defp applies?({:call_fun2, _, _, _}), do: true
  defp applies?({:apply, _}), do: true
  defp applies?({:apply_last, _, _}), do: true

  defp applies?(instr) do
    match?({:ok, :erlang, :apply, _}, match_remote_call(instr))
  end

  # Elixir's `send/2` is a call to :erlang.send/2, not the `send` opcode
  # (which Erlang's `!` compiles to); both count.
  defp first_send(instrs) do
    case Enum.find_index(instrs, &send?/1) do
      nil -> {false, 0}
      idx -> {true, idx}
    end
  end

  defp send?(:send), do: true
  defp send?({:send}), do: true

  defp send?(instr) do
    match?({:ok, :erlang, :send, a} when a in [2, 3], match_remote_call(instr))
  end

  # The BEAM try instruction is {:try, register, {:f, handler_label}}.
  # After the handler label, {:try_case, register} begins the catch handler.
  defp maybe_bare_rescue(facts, ctx, {:try, _reg, {:f, handler_label}}) do
    if bare_handler?(ctx.instrs, handler_label) do
      id = InstrId.mint(ctx.func_id, ctx.idx)
      add_fact(facts, :bare_rescue, [id, ctx.func_id])
    else
      facts
    end
  end

  defp maybe_bare_rescue(facts, _ctx, _instr), do: facts

  # The calls a try guards that a rule asks about: the ones whose failure
  # arrives as an exit or an error the handler is expected to classify.
  @guarded_calls [
    {GenServer, :call, 2},
    {GenServer, :call, 3},
    {:gen_server, :call, 2},
    {:gen_server, :call, 3},
    {:gen_statem, :call, 2},
    {:gen_statem, :call, 3},
    {GenStateMachine, :call, 2},
    {GenStateMachine, :call, 3},
    {:erpc, :call, 4},
    {:erpc, :call, 5},
    {:rpc, :call, 4},
    {:rpc, :call, 5}
  ]

  defp maybe_catch_clauses(facts, ctx, {:try, reg, {:f, handler_label}}) do
    id = InstrId.mint(ctx.func_id, ctx.idx)
    summary = CatchClauses.analyse(ctx.instrs, handler_label)

    facts =
      Enum.reduce(summary.totals, facts, fn class, acc ->
        add_fact(acc, :catch_total, [id, ctx.func_id, to_string(class)])
      end)

    facts =
      Enum.reduce(summary.tags, facts, fn {class, tag}, acc ->
        add_fact(acc, :catch_tag, [id, ctx.func_id, to_string(class), inspect(tag)])
      end)

    facts =
      Enum.reduce(summary.falls_through, facts, fn tag, acc ->
        add_fact(acc, :catch_falls_through, [id, ctx.func_id, inspect(tag)])
      end)

    ctx.instrs
    |> Enum.drop(ctx.idx + 1)
    |> Enum.take_while(fn
      {:try_end, ^reg} -> false
      {:try_case, ^reg} -> false
      {:func_info, _, _, _} -> false
      _ -> true
    end)
    |> Enum.reduce(facts, fn instr, acc ->
      case match_remote_call(instr) do
        {:ok, m, f, a} when {m, f, a} in @guarded_calls ->
          add_fact(acc, :try_call, [id, ctx.func_id, Normalize.func_id(m, f, a)])

        _ ->
          acc
      end
    end)
  end

  defp maybe_catch_clauses(facts, _ctx, _instr), do: facts

  # Check whether a handler starting at the given label is a bare rescue.
  # A bare rescue catches all exceptions without filtering the exception
  # class and without reraising. The handler starts after {:try_case, _}
  # and extends until the next label, return, or function boundary.
  defp bare_handler?(instrs, handler_label) do
    handler_instrs = instructions_from_label(instrs, handler_label)
    # Skip the label itself and try_case to get to the handler body.
    handler_body = take_handler_body(handler_instrs)

    has_filter? =
      Enum.any?(handler_body, fn
        {:test, _, _, _} -> true
        {:select_val, _, _, _} -> true
        _ -> false
      end)

    has_reraise? =
      Enum.any?(handler_body, fn
        {:bif, :raise, _, _, _} ->
          true

        # Since OTP 21, `:erlang.raise(kind, reason, __STACKTRACE__)` in a
        # catch handler compiles to the standalone `raw_raise` opcode, not
        # a call to :erlang.raise/3 — so a re-raising handler (NimblePool,
        # DBConnection.run) was read as swallowing.
        :raw_raise ->
          true

        {:raw_raise} ->
          true

        instr ->
          case match_remote_call(instr) do
            {:ok, :erlang, :raise, 3} -> true
            {:ok, :erlang, :error, _} -> true
            _ -> false
          end
      end)

    # It's a bare rescue if it neither filters the exception class,
    # reraises, nor reifies the caught exception into a value it returns,
    # logs, or hands to another function.
    not has_filter? and not has_reraise? and not reifies_exception?(handler_body) and
      handler_body != []
  end

  # After `{:try_case, _}` the caught exception occupies x0 (class), x1
  # (reason), and x2 (stacktrace). A handler that reads any of them before
  # overwriting it is doing something with the exception — returning
  # `{:error, reason}`, logging it, passing it to a handler function — not
  # silently swallowing it. A truly-bare handler (`catch _, _ -> :ok` /
  # `-> default`) overwrites x0 with its return value and never reads the
  # exception registers. This is a small liveness scan: start with the
  # three exception registers live, and report a read the moment a live
  # one is used as a source, tracking overwrites so a reused register
  # (the return value later moved through x0) is not mistaken for the
  # exception.
  @exception_regs MapSet.new([{:x, 0}, {:x, 1}, {:x, 2}])

  defp reifies_exception?(handler_body) do
    result =
      Enum.reduce_while(handler_body, @exception_regs, fn instr, live ->
        if Enum.any?(source_regs(instr), &MapSet.member?(live, &1)) do
          {:halt, :reifies}
        else
          {:cont, MapSet.difference(live, MapSet.new(dest_regs(instr)))}
        end
      end)

    result == :reifies
  end

  # Registers read (as source operands) by an instruction. Only the shapes
  # that can appear in a catch handler and can carry an exception register
  # are enumerated; anything else reads nothing relevant. A call of arity N
  # reads x0..x(N-1) (its argument registers).
  defp source_regs({:move, src, _dst}), do: regs([src])
  defp source_regs({:swap, a, b}), do: regs([a, b])
  defp source_regs({:put_list, hd, tl, _dst}), do: regs([hd, tl])
  defp source_regs({:put_tuple2, _dst, {:list, elems}}), do: regs(elems)
  defp source_regs({:get_tuple_element, src, _idx, _dst}), do: regs([src])
  defp source_regs({:get_hd, src, _dst}), do: regs([src])
  defp source_regs({:get_tl, src, _dst}), do: regs([src])
  defp source_regs({:call, arity, _}), do: arg_regs(arity)
  defp source_regs({:call_only, arity, _}), do: arg_regs(arity)
  defp source_regs({:call_last, arity, _, _}), do: arg_regs(arity)
  defp source_regs({:call_ext, arity, _}), do: arg_regs(arity)
  defp source_regs({:call_ext_only, arity, _}), do: arg_regs(arity)
  defp source_regs({:call_ext_last, arity, _, _}), do: arg_regs(arity)
  defp source_regs({:bif, _name, _fail, args, _dst}) when is_list(args), do: regs(args)
  defp source_regs({:gc_bif, _name, _fail, _live, args, _dst}) when is_list(args), do: regs(args)
  defp source_regs({:test, _op, _fail, args}) when is_list(args), do: regs(args)
  # raw_raise / build_stacktrace operate on the caught exception in place.
  defp source_regs(:raw_raise), do: [{:x, 0}]
  defp source_regs({:raw_raise}), do: [{:x, 0}]
  defp source_regs(:build_stacktrace), do: [{:x, 0}]
  defp source_regs({:build_stacktrace}), do: [{:x, 0}]
  defp source_regs(_instr), do: []

  # Registers written (as destination) by an instruction — removed from the
  # live exception set so a later reuse of the register is not mistaken for
  # a read of the exception. A call writes its result to x0.
  defp dest_regs({:move, _src, dst}), do: regs([dst])
  defp dest_regs({:swap, a, b}), do: regs([a, b])
  defp dest_regs({:put_list, _hd, _tl, dst}), do: regs([dst])
  defp dest_regs({:put_tuple2, dst, _}), do: regs([dst])
  defp dest_regs({:get_tuple_element, _src, _idx, dst}), do: regs([dst])
  defp dest_regs({:get_hd, _src, dst}), do: regs([dst])
  defp dest_regs({:get_tl, _src, dst}), do: regs([dst])
  defp dest_regs({:call, _, _}), do: [{:x, 0}]
  defp dest_regs({:call_only, _, _}), do: [{:x, 0}]
  defp dest_regs({:call_last, _, _, _}), do: [{:x, 0}]
  defp dest_regs({:call_ext, _, _}), do: [{:x, 0}]
  defp dest_regs({:call_ext_only, _, _}), do: [{:x, 0}]
  defp dest_regs({:call_ext_last, _, _, _}), do: [{:x, 0}]
  defp dest_regs({:bif, _name, _fail, _args, dst}), do: regs([dst])
  defp dest_regs({:gc_bif, _name, _fail, _live, _args, dst}), do: regs([dst])
  defp dest_regs(_instr), do: []

  # Normalize operands to plain registers, dropping literals/atoms/labels.
  defp regs(operands), do: operands |> Enum.map(&to_reg/1) |> Enum.reject(&is_nil/1)

  defp to_reg({:x, _} = reg), do: reg
  defp to_reg({:y, _} = reg), do: reg
  defp to_reg({:tr, inner, _type}), do: to_reg(inner)
  defp to_reg(_operand), do: nil

  defp arg_regs(arity) when arity > 0, do: for(i <- 0..(arity - 1), do: {:x, i})
  defp arg_regs(_arity), do: []

  # Extract handler body: skip labels and try_case, take until next
  # label, try, func_info, or function boundary.
  defp take_handler_body([]), do: []
  defp take_handler_body([{:label, _} | rest]), do: take_handler_body(rest)
  defp take_handler_body([{:try_case, _} | rest]), do: take_handler_body(rest)

  defp take_handler_body(instrs) do
    Enum.take_while(instrs, fn
      {:label, _} -> false
      {:try, _, _} -> false
      {:try_end, _} -> false
      {:try_case, _} -> false
      {:func_info, _, _, _} -> false
      _ -> true
    end)
  end

  # Handle remote calls relevant to error-handling: trap_exit, exit calls,
  # and ignored error results from known {ok, _} | {error, _} APIs.
  defp error_handling_call(facts, mod_str, ctx, mfa) do
    case mfa do
      {Process, :flag, 2} ->
        maybe_trap_exit(facts, ctx, mod_str)

      {:erlang, :process_flag, 2} ->
        maybe_trap_exit(facts, ctx, mod_str)

      {Process, :exit, 2} ->
        emit_exit_call(facts, ctx, resolve_atom(ctx.instrs, ctx.idx, {:x, 0}))

      {:erlang, :exit, 1} ->
        emit_exit_call(facts, ctx, "self")

      {:erlang, :exit, 2} ->
        emit_exit_call(facts, ctx, resolve_atom(ctx.instrs, ctx.idx, {:x, 0}))

      {mod, func, arity} ->
        maybe_ignored_result(facts, ctx, mod, func, arity)
    end
  end

  defp emit_exit_call(facts, ctx, target) do
    id = InstrId.mint(ctx.func_id, ctx.idx)

    facts
    |> track_dynamic(target, ctx, :exit_call_target, :exit_call)
    |> add_fact(:exit_call, [id, ctx.func_id, target])
  end

  defp maybe_trap_exit(facts, ctx, mod_str) do
    case resolve_register(ctx.instrs, ctx.idx, {:x, 0}) do
      {:ok, :trap_exit} ->
        case resolve_register(ctx.instrs, ctx.idx, {:x, 1}) do
          {:ok, true} ->
            add_fact(facts, :trap_exit, [ctx.func_id, mod_str])

          {:ok, false} ->
            # Explicit Process.flag(:trap_exit, false) — not imprecision.
            facts

          _ ->
            track_imprecision(facts, ctx, :trap_exit_unresolved, :trap_exit, :skipped)
        end

      _ ->
        # Not a trap_exit call (e.g. Process.flag(:priority, :high)).
        facts
    end
  end

  # Check if the result of a call is ignored — if the instruction after the
  # call does not test/branch on the result register (x0).
  #
  # Four outcomes:
  # 1. Tail call (call_ext_only / call_ext_last) — result IS the function's
  #    return value, so it's definitively used. No fact, no imprecision.
  # 2. Non-tail call where the next instruction overwrites x0 — result IS
  #    ignored. Emit ignored_error_result fact.
  # 3. Non-tail call where the next instruction reads/tests/saves x0 —
  #    result IS actively used. No fact, no imprecision.
  # 4. None of the above — the heuristic gives up. Emit imprecision event.
  defp maybe_ignored_result(facts, ctx, mod, func, arity) do
    if MapSet.member?(@ok_error_apis, {mod, func, arity}) do
      instr = Enum.at(ctx.instrs, ctx.idx)
      after_call = Enum.drop(ctx.instrs, ctx.idx + 1)

      cond do
        # Tail calls return their result to the caller — not ignored.
        tail_call?(instr) ->
          facts

        # Non-tail call where x0 is immediately overwritten.
        result_ignored?(after_call) ->
          id = InstrId.mint(ctx.func_id, ctx.idx)
          callee = "#{inspect(mod)}.#{func}/#{arity}"
          add_fact(facts, :ignored_error_result, [id, ctx.func_id, callee])

        # Non-tail call where x0 is actively consumed (saved, tested,
        # destructured, or branched on).
        result_used?(after_call) ->
          facts

        # Can't determine the result's fate.
        true ->
          track_imprecision(
            facts,
            ctx,
            :ignored_result_unknown_api,
            :ignored_error_result,
            :skipped
          )
      end
    else
      facts
    end
  end

  # Tail call variants — the function returns whatever the callee returns.
  defp tail_call?({:call_ext_only, _, _}), do: true
  defp tail_call?({:call_ext_last, _, _, _}), do: true
  defp tail_call?(_), do: false

  # Result is overwritten before being read — ignored.
  defp result_ignored?([{:move, _, {:x, 0}} | _]), do: true
  defp result_ignored?([{:move, _, {:tr, {:x, 0}, _}} | _]), do: true
  defp result_ignored?(_), do: false

  # Result is actively consumed by the next instruction — used.
  # Saved to a y-register (stack) for use across subsequent calls.
  defp result_used?([{:move, {:x, 0}, {:y, _}} | _]), do: true
  defp result_used?([{:move, {:tr, {:x, 0}, _}, {:y, _}} | _]), do: true
  defp result_used?([{:move, {:x, 0}, {:tr, {:y, _}, _}} | _]), do: true
  # Pattern matching / branching on x0.
  defp result_used?([{:test, _, _, [{:x, 0} | _]} | _]), do: true
  defp result_used?([{:test, _, _, [_, {:x, 0}]} | _]), do: true
  defp result_used?([{:test, _, _, [{:tr, {:x, 0}, _} | _]} | _]), do: true
  defp result_used?([{:select_val, {:x, 0}, _, _} | _]), do: true
  # Tuple destructuring of x0 (e.g. {:ok, value} = call()).
  defp result_used?([{:get_tuple_element, {:x, 0}, _, _} | _]), do: true
  defp result_used?([{:get_tuple_element, {:tr, {:x, 0}, _}, _, _} | _]), do: true
  # x0 used as argument to the next call (passed forward).
  defp result_used?([{:call_ext, _, _} | _]), do: true
  defp result_used?([{:call, _, _} | _]), do: true
  defp result_used?(_), do: false
end
