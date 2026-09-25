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
  - `call_result(id, func, callee, fate, raises, target)` — every call to a process
    or OTP API (and every `start_link`/`start`/`start_child`), with what
    became of its result (`used`, `ignored`, `returned` for a tail call,
    `dynamic`), the class it raises when it fails (`exit` for a call into
    a process, `error` for a BIF or an ETS operation, `*` when either),
    and its first argument when that is a literal (the table, the name).
    Whether a try takes what it raises is try_covers and catch_class.
    The population a consistency rule counts: which fate the other call
    sites of the same callee chose is the belief, and the odd one out is
    the finding (Engler et al., "Bugs as deviant behavior").
  - `ignored_error_result(id, func, callee)` — call to known ok/error API where
    result is not pattern matched
  - `catch_class(id, func, class, span_end)` — some path through the
    handler of the try (or Erlang `catch`) at `id` catches `class` and
    does not raise again (`*`: with no class test)
  - `catch_total(id, func, class)` — some clause catches `class` without
    a pattern on the reason
  - `catch_tag(id, func, class, tag)` — an atom a clause catching `class`
    compares against (its reason pattern, or a `case` in its body);
    `rescue X` yields the struct name `X`
  - `catch_tuple_tag(id, func, class, tag)` — the catch_tag atoms a
    clause compares as a tuple's first element (`{:noproc, _}`), not
    the reason itself (`:noproc`)
  - `catch_falls_through(id, func, tag)` — a `case` inside the handler,
    reached after comparing `tag`, has no clause for some value, so an
    unexpected reason is a CaseClauseError
  - `try_covers(id, func, call, kind)` — the try (or Erlang `catch`) at
    `id` covers the call at `call`: an exception the call raises goes to
    that try's handler
  - `try_covers_closure(id, func, closure)` — every read of the closure
    `closure`'s value is a call the try (or `catch`) at `id` covers
  - `try_call(id, func, callee, call, guard_end)` — a peer call (`GenServer.call`,
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
  - `timer_tag(id, tag)` — the atom the message of the timer armed at
    `id` is told apart by: the message itself, or a tuple's first element
  - `cancel_clause(id, func, message)` — a cancel_timer inside a
    `handle_info/2` clause whose head is the literal `message`
  - `rpc_result(id, func, handling)` — how the result of an :rpc/:erpc
    call is treated: `badrpc`, `boolean`, `case`, `matched`, `returned`
    or `other`
  """

  @behaviour Argus.Extractor

  alias Argus.Cfg.Walk
  alias Argus.Extractor.CallSites
  alias Argus.Extractor.Dispatch
  alias Argus.Extractor.Helpers
  alias Argus.Extractor.Identity
  alias Argus.Extractor.Resolve
  alias Argus.Extractors.ErrorHandling.CatchClauses
  alias Argus.Extractors.ErrorHandling.ClauseHead
  alias Argus.Instr
  alias Argus.Instr.Reaching
  alias Argus.InstrId
  alias Argus.Pipeline.Normalize

  import Argus.Extractor.Helpers,
    only: [
      each_remote_call: 3,
      find_function: 3,
      instructions_from_label: 2,
      match_local_call: 1,
      match_remote_call: 1,
      register: 1,
      scan_functions: 4
    ]

  import Argus.Extractor.Facts, only: [add_fact: 3, track_dynamic: 5, track_imprecision: 5]
  import Argus.Extractor.Identity, only: [key_identity: 4]

  import Argus.Extractor.Resolve,
    only: [
      arg_position: 3,
      call_result_origin: 3,
      map_field_of: 3,
      resolve_atom: 3,
      resolve_register: 3
    ]

  import Argus.Extractor.Terms, only: [spell: 1]

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
      :call_result,
      :cancel_clause,
      :catch_falls_through,
      :catch_class,
      :catch_tag,
      :catch_total,
      :catch_tuple_tag,
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
      :timer_tag,
      :trap_exit,
      :try_call,
      :try_covers,
      :try_covers_closure
    ]

  @impl true
  @spec extract(Argus.Extractor.module_data()) :: Argus.Pipeline.Emit.facts()
  def extract(module_data) do
    mod = module_data.module
    mod_str = inspect(mod)
    line_table = Map.get(module_data, :line_table, %{})

    rescues =
      scan_functions(mod, module_data.functions, %{}, fn facts, ctx, instr ->
        ctx = Map.put(ctx, :line_table, line_table)

        facts
        |> maybe_bare_rescue(ctx, instr)
        |> maybe_catch_clauses(ctx, instr)
      end)

    rescues =
      rescues
      |> emit_self_sends(mod, module_data.functions)
      |> emit_timer_flows(mod, module_data.functions)
      |> emit_cancel_clauses(module_data)
      |> emit_try_coverage(module_data)

    origins = Identity.origins_index(module_data)

    each_remote_call(module_data, rescues, fn facts, ctx, mfa ->
      ctx =
        ctx
        |> Map.put(:line_table, line_table)
        |> Map.put(:origins, {origins, ctx.func_id})

      facts
      |> error_handling_call(mod_str, ctx, mfa)
      |> maybe_mailbox_writer(ctx, mfa, module_data.functions)
      |> maybe_rpc_result(ctx, mfa)
      |> maybe_call_result(ctx, mfa)
    end)
  end

  # The callees whose results a consistency rule may compare across the
  # program: process and OTP APIs, and anything that starts a process.
  # Every shipped analysis targets a BEAM-specific bug class, so a
  # File.write ignored once in twelve is not this analysis's business.
  @process_modules [
    GenServer,
    Supervisor,
    DynamicSupervisor,
    PartitionSupervisor,
    Registry,
    Task,
    Task.Supervisor,
    Agent,
    Process,
    :gen_server,
    :gen_statem,
    :supervisor,
    :ets
  ]

  # :erlang is every BIF there is; only its process half belongs here.
  @erlang_process_functions ~w(spawn spawn_link spawn_monitor spawn_opt send send_after start_timer
    cancel_timer read_timer monitor demonitor link unlink register unregister whereis
    process_flag exit)a

  @start_functions [:start_link, :start, :start_child]

  defp maybe_call_result(facts, ctx, {mod, func, arity}) do
    if process_api?(mod, func) and not generated_function?(ctx.func_id) do
      add_fact(facts, :call_result, [
        InstrId.mint(ctx.func_id, ctx.idx),
        ctx.func_id,
        Normalize.func_id(mod, func, arity),
        result_fate(ctx),
        raises(mod),
        call_target(ctx)
      ])
    else
      facts
    end
  end

  # The class a failing call raises, which a guard must take to guard it.
  # A call into a process — a GenServer, a supervisor, an agent, a task
  # awaited — fails with an exit (noproc, timeout, the server's own
  # crash); a BIF or an ETS operation with an error (badarg). A start
  # function of the program's own is either, or neither: any class a
  # handler takes counts ("*").
  @exit_modules [
    GenServer,
    Supervisor,
    DynamicSupervisor,
    PartitionSupervisor,
    Task,
    Task.Supervisor,
    Agent,
    :gen_server,
    :gen_statem,
    :supervisor
  ]

  @error_modules [Registry, Process, :erlang, :ets]

  defp raises(mod) when mod in @exit_modules, do: "exit"
  defp raises(mod) when mod in @error_modules, do: "error"
  defp raises(_mod), do: "*"

  # What the call acts on, when its first argument is a literal: the
  # table, the server name, the supervisor. Sites on different targets
  # keep different conventions — mnesia reads its own gvar table under a
  # catch 120 times and its stats table bare once, on purpose — so the
  # belief a site is judged by is its target's. Empty when not literal.
  defp call_target(%{instrs: instrs, idx: idx}) do
    case key_identity(instrs, idx, {:x, 0}, nil) do
      {"literal", value} -> value
      _other -> ""
    end
  end

  defp process_api?(:erlang, func), do: func in @erlang_process_functions
  defp process_api?(mod, func), do: mod in @process_modules or func in @start_functions

  # __info__/1 and module_info/0,1 call :erlang.get_module_info; they are
  # the compiler's sites, not the program's.
  defp generated_function?(func_id) do
    {name, _arity} = Normalize.func_id_name_arity(func_id)
    name in ["__info__", "module_info"] or String.starts_with?(name, "-inlined-")
  end

  # The same reading maybe_ignored_result/5 makes, as a value: a tail call
  # returns the result to the caller, the next instruction either
  # overwrites x0 or reads it, and anything else is unknown.
  defp result_fate(ctx) do
    instr = Enum.at(ctx.instrs, ctx.idx)
    after_call = Enum.drop(ctx.instrs, ctx.idx + 1)

    cond do
      Instr.tail_call?(instr) -> "returned"
      result_ignored?(after_call) -> "ignored"
      result_used?(after_call) -> "used"
      true -> "dynamic"
    end
  end

  # The handler's own line marker on the highest source line, minted as
  # a site: where a span from the guarded call through its catch ends.
  # Only markers count — an instruction with no marker of its own
  # inherits whatever line preceded it, and the compiler's re-raise
  # block inherits the line of the code after the try — and only the
  # handler's own: a handler that is not in tail position runs on into
  # the code after the `try`, which is also reached from the try's normal
  # exit. Empty when the handler has no marker (a catch whose body is a
  # literal), and when the caller supplied no Line table (a bare
  # disassembly; the pipeline supplies one).
  defp handler_end(ctx, label, try_idx) do
    instrs = List.to_tuple(ctx.instrs)
    line_table = Map.get(ctx, :line_table, %{})
    after_try = MapSet.new(after_try(ctx.instrs, try_idx))

    own =
      Enum.reject(CatchClauses.analyse(ctx.instrs, label).visited, &MapSet.member?(after_try, &1))

    markers =
      for idx <- own,
          {:line, ref} <- [elem(instrs, idx)],
          line = Map.get(line_table, ref),
          is_integer(line),
          do: {line, idx}

    case markers do
      [] -> ""
      _ -> InstrId.mint(ctx.func_id, markers |> Enum.max() |> elem(1))
    end
  end

  # The instructions reached from the try's normal exit.
  defp after_try(instrs, try_idx) do
    {:try, reg, _handler} = Enum.at(instrs, try_idx)

    instrs
    |> Enum.drop(try_idx + 1)
    |> Enum.find_index(&match?({:try_end, ^reg}, &1))
    |> case do
      nil -> []
      offset -> CatchClauses.reach(instrs, try_idx + 1 + offset + 1)
    end
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

  defp maybe_mailbox_writer(facts, ctx, mfa, functions) do
    case Map.fetch(@mailbox_writers, mfa) do
      {:ok, {"timer", msg_reg, dest}} ->
        id = InstrId.mint(ctx.func_id, ctx.idx)
        {message, param, literal} = timer_message(ctx, msg_reg)
        kind = if message == "bare", do: "timer_bare", else: "timer"
        {flow, key} = ref_flow(ctx.instrs, ctx.idx, functions)

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
        |> emit_timer_tag(id, timer_tag(ctx, msg_reg))

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
        if bare_message?(msg), do: {"bare", -1, spell(msg)}, else: {"dynamic", -1, ""}

      _ ->
        case arg_position(ctx.instrs, ctx.idx, {:x, msg_reg}) do
          {:ok, n} -> {"param", n, ""}
          :no -> {"dynamic", -1, ""}
        end
    end
  end

  # The atom a receive or a clause head tells the timer's message apart
  # by: the message itself when it is an atom, or the first element of a
  # tuple, literal or built (`{:retry, attempts - 1}`, whose other
  # elements the resolver leaves `:dynamic`). Nil for any other message,
  # and for one the resolver cannot follow.
  defp timer_tag(ctx, msg_reg) do
    case resolve_register(ctx.instrs, ctx.idx, {:x, msg_reg}) do
      {:ok, atom} when is_atom(atom) and atom != :dynamic ->
        inspect(atom)

      {:ok, tuple} when is_tuple(tuple) and tuple_size(tuple) > 0 ->
        case elem(tuple, 0) do
          tag when is_atom(tag) and tag != :dynamic -> inspect(tag)
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp emit_timer_tag(facts, _id, nil), do: facts
  defp emit_timer_tag(facts, id, tag), do: add_fact(facts, :timer_tag, [id, tag])

  # Where the timer ref goes after the arming call: returned by the
  # function (a helper like `defp arm(ms), do: Process.send_after(...)`),
  # stored under a literal key of a map (`%{state | timer: ...}`,
  # `Map.put(state, :timer, ...)`), or somewhere the walk cannot follow.
  # Handed to a function of this module (`put_timer(state, ref)`), it goes
  # where that function puts its parameter: stored there, or returned
  # into the call's result, which the walk then follows.
  defp ref_flow(instrs, idx, functions) do
    env = %{functions: functions, seen: %{}}

    if Instr.tail_call?(Enum.at(instrs, idx)),
      do: {"returned", ""},
      else: ref_walk(Enum.drop(instrs, idx + 1), [{:x, 0}], instrs, idx + 1, env)
  end

  defp ref_walk([], _aliases, _instrs, _at, _env), do: {"dynamic", ""}

  defp ref_walk([:return | _], aliases, _instrs, _at, _env),
    do: if({:x, 0} in aliases, do: {"returned", ""}, else: {"dynamic", ""})

  defp ref_walk([{:move, src, dst} | rest], aliases, instrs, at, env),
    do: ref_walk(rest, retarget(aliases, src, dst), instrs, at + 1, env)

  defp ref_walk(
         [{put_map, _f, _src, dst, _live, {:list, pairs}} | rest],
         aliases,
         instrs,
         at,
         env
       )
       when put_map in [:put_map_assoc, :put_map_exact] do
    case stored_key(pairs, aliases) do
      {:ok, key} -> {"stored", key}
      :none -> ref_walk(rest, List.delete(aliases, register(dst)), instrs, at + 1, env)
    end
  end

  # Map.put(map, key, value) compiles to :maps.put(key, value, map).
  defp ref_walk([{:call_ext, 3, {:extfunc, :maps, :put, 3}} | _rest], aliases, instrs, at, _env) do
    with true <- {:x, 1} in aliases,
         {:ok, key} when is_atom(key) <- resolve_register(instrs, at, {:x, 0}) do
      {"stored", inspect(key)}
    else
      _ -> {"dynamic", ""}
    end
  end

  defp ref_walk([{:label, _} | _], _aliases, _instrs, _at, _env), do: {"dynamic", ""}

  # Any other call takes the ref somewhere the walk does not follow, or
  # clobbers it; a tail call, a jump, a raise end the path here — the
  # walk is linear, and what follows is another path.
  defp ref_walk([instr | rest], aliases, instrs, at, env) do
    case handed_to_helper(instr, aliases, env) do
      {:stored, key} ->
        {"stored", key}

      :returned ->
        if Instr.tail_call?(instr),
          do: {"returned", ""},
          else: ref_walk(rest, [{:x, 0} | y_aliases(aliases)], instrs, at + 1, env)

      :none ->
        if Instr.call?(instr) or not Instr.falls_through?(instr),
          do: {"dynamic", ""},
          else: ref_walk(rest, Instr.carry(instr, aliases), instrs, at + 1, env)
    end
  end

  # A call to a function of this module with the ref as argument k: where
  # the function puts its parameter k, walked from its entry.
  defp handed_to_helper(instr, aliases, env) do
    with {:ok, _mod, fun, arity} <- match_local_call(instr),
         k when is_integer(k) <-
           Enum.find_value(aliases, fn
             {:x, k} when k < arity -> k
             _ -> nil
           end),
         false <- Map.has_key?(env.seen, {fun, arity, k}),
         helper when helper != nil <- find_function(env.functions, fun, arity),
         {:ok, body, at} <- body_of(helper) do
      env = %{env | seen: Map.put(env.seen, {fun, arity, k}, true)}

      case ref_walk(body, [{:x, k}], helper, at, env) do
        {"stored", key} -> {:stored, key}
        {"returned", _} -> :returned
        _ -> :none
      end
    else
      _ -> :none
    end
  end

  # A function's code after its func_info and entry label, and the index
  # it starts at.
  defp body_of(instrs) do
    case Enum.find_index(instrs, &match?({:func_info, _, _, _}, &1)) do
      nil -> :error
      i -> {:ok, Enum.drop(instrs, i + 2), i + 2}
    end
  end

  defp y_aliases(aliases), do: Enum.filter(aliases, &match?({:y, _}, &1))

  defp stored_key(pairs, aliases) do
    pairs
    |> Enum.chunk_every(2)
    |> Enum.find_value(:none, fn
      [{:atom, key}, val] -> if alias?(val, aliases), do: {:ok, inspect(key)}, else: nil
      [{:literal, key}, val] -> if alias?(val, aliases), do: {:ok, spell(key)}, else: nil
      _ -> nil
    end)
  end

  # Where the cancelled ref came from: a map field read in this function
  # (`state.timer`, or a `%{timer: ref}` head), a parameter (nebulex's
  # `start_timer(time, ref, event)`), the value one instruction of this
  # function made — the send_after it armed, keyed by that site — or
  # unknown.
  defp cancel_source(ctx) do
    case map_field_of(ctx.instrs, ctx.idx, {:x, 0}) do
      {:ok, key} ->
        {"field", key, -1}

      :dynamic ->
        case arg_position(ctx.instrs, ctx.idx, {:x, 0}) do
          {:ok, n} -> {"param", "", n}
          :no -> local_cancel_source(ctx)
        end
    end
  end

  defp local_cancel_source(ctx) do
    case key_identity(ctx.instrs, ctx.idx, {:x, 0}, Map.get(ctx, :origins)) do
      {"local", site} -> {"local", site, -1}
      _other -> {"dynamic", "", -1}
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

  # A cancel inside a handle_info/2 clause whose head is a literal
  # message: `def handle_info(:heartbeat, s)` cancelling the ref of the
  # timer that sent :heartbeat cancels a timer that has already fired.
  # Which calls each try covers. A try's protected region is not the
  # instructions between `try` and `try_end` in the stream: it is every
  # instruction on a path from the `try` that has not yet passed its
  # `try_end` (or reached its `try_case`, the handler, which runs with the
  # try already closed). Walked on the function's graph, so a region that
  # jumps out to shared code and back, a nested try's handler (still inside
  # the outer region, whose handler takes what it re-raises), and code the
  # compiler placed after the handler all fall where control puts them.
  # Erlang's `catch Expr` is the same shape, ended by `catch_end`, which
  # both paths reach.
  defp emit_try_coverage(facts, module_data) do
    mod = module_data.module

    Enum.reduce(module_data.functions, facts, fn {:function, name, arity, _entry, instrs}, acc ->
      regions =
        for {{op, reg, {:f, _handler}}, idx} <- Enum.with_index(instrs),
            op in [:try, :catch],
            do: {op, reg, idx}

      case regions do
        [] ->
          acc

        _ ->
          fun = Helpers.cfg(module_data, name, arity)
          func_id = Normalize.func_id(mod, name, arity)
          closures = closure_uses(instrs)
          Enum.reduce(regions, acc, &cover(&2, fun, func_id, instrs, closures, &1))
      end
    end)
  end

  # No graph (the function's could not be built): no rows, and a rule
  # asking whether a call is covered reads it as bare.
  defp cover(facts, nil, _func_id, _instrs, _closures, _region), do: facts

  defp cover(facts, fun, func_id, instrs, closures, {op, reg, idx}) do
    {:done, visited} =
      Walk.explore(fun, instrs, [idx + 1],
        on_instr: fn instr, at ->
          if at == idx or region_end?(op, reg, instr), do: :prune, else: :continue
        end
      )

    table = List.to_tuple(instrs)
    id = InstrId.mint(func_id, idx)

    facts =
      visited
      |> Enum.sort()
      |> Enum.filter(fn at ->
        instr = elem(table, at)
        Instr.call?(instr) or Instr.tail_call?(instr)
      end)
      |> Enum.reduce(facts, fn at, acc ->
        add_fact(acc, :try_covers, [id, func_id, InstrId.mint(func_id, at), to_string(op)])
      end)

    # A closure whose every use is a call inside the region — handed to
    # Enum.each there, or called — runs under the handler. The compiler
    # hoists a closure with nothing to capture out of the try, so where
    # it is built says nothing; where its value goes does.
    in_region = MapSet.new(visited)

    closures
    |> Enum.filter(fn {_closure, uses} ->
      Enum.all?(uses, fn at ->
        MapSet.member?(in_region, at) and Instr.call?(elem(table, at))
      end)
    end)
    |> Enum.map(&elem(&1, 0))
    |> Enum.sort()
    |> Enum.reduce(facts, fn closure, acc ->
      add_fact(acc, :try_covers_closure, [id, func_id, closure])
    end)
  end

  # Each closure the function builds, with every instruction that reads
  # its value other than to copy it: a call it is handed to, or anything
  # else it escapes into (a tuple, a message, the return). A closure
  # whose value nothing reads is left out: it runs nowhere.
  defp closure_uses(instrs) do
    builds =
      instrs
      |> Enum.with_index()
      |> Enum.flat_map(fn
        {{:make_fun3, {m, f, a}, _, _, _, _}, at} -> [{InstrId.func_id(m, f, a), at}]
        _other -> []
      end)
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

    if builds == %{} do
      []
    else
      indexed = Enum.with_index(instrs)

      for {closure, at} <- builds,
          uses = fun_uses(instrs, indexed, Map.new(at, &{&1, true})),
          uses != [],
          do: {closure, uses}
    end
  end

  defp fun_uses(instrs, indexed, builds) do
    for {instr, at} <- indexed,
        reg <- Instr.uses(instr),
        not copy_of?(instr, reg),
        holds_fun?(instrs, at, reg, builds, %{}),
        uniq: true,
        do: at
  end

  defp copy_of?(instr, reg) do
    Instr.defs(instr) != [] and
      Enum.all?(Instr.defs(instr), &(Instr.copy_source(instr, &1) == reg))
  end

  # Whether `reg` can hold the fun one of `builds` made when control
  # reaches `at`: written there by the build, or copied from a register
  # that held it. `builds` and `seen` are plain maps: a MapSet is opaque
  # to dialyzer through the recursion.
  defp holds_fun?(instrs, at, reg, builds, seen) do
    Reaching.sources(instrs, at, reg)
    |> Enum.any?(fn
      {:param, _} ->
        false

      src ->
        cond do
          Map.has_key?(builds, src) ->
            true

          Map.has_key?(seen, {src, reg}) ->
            false

          true ->
            case Instr.copy_source(Reaching.at(instrs, src), reg) do
              nil -> false
              from -> holds_fun?(instrs, src, from, builds, Map.put(seen, {src, reg}, true))
            end
        end
    end)
  end

  defp region_end?(:try, reg, {:try_end, reg}), do: true
  defp region_end?(:try, reg, {:try_case, reg}), do: true
  defp region_end?(:catch, reg, {:catch_end, reg}), do: true
  defp region_end?(_op, _reg, _instr), do: false

  defp emit_cancel_clauses(facts, module_data) do
    for %{mfa: mfa, func_id: func_id, instrs: instrs, idx: idx} <-
          CallSites.for_module(module_data),
        Map.get(@mailbox_writers, mfa) == "cancel",
        Normalize.func_id_name_arity(func_id) == {"handle_info", 2},
        fun = Helpers.cfg(module_data, "handle_info", 2),
        fun != nil,
        message = ClauseHead.atom_at(fun, instrs, idx),
        message != nil,
        reduce: facts do
      acc -> add_fact(acc, :cancel_clause, [InstrId.mint(func_id, idx), func_id, message])
    end
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
    with {kind, _} = r when kind in [:x, :y] <- register(val),
         {:ok, {m, f, a}, _origin} <- call_result_origin(instrs, idx, r) do
      callee = InstrId.func_id(if(m == :local, do: mod, else: m), f, a)
      add_fact(facts, :timer_store, [func_id, spell(key), callee])
    else
      _ -> facts
    end
  end

  # Each instruction with the one after it (nil after the last): a pass
  # over the list rather than an `Enum.at/2` per instruction, which was
  # quadratic in the function (50 s on ex_cldr's 54k-instruction lexer).
  defp emit_returns(facts, mod, func_id, instrs) do
    instrs
    |> Enum.zip(Enum.drop(instrs, 1) ++ [nil])
    |> Enum.reduce(facts, fn {instr, next}, acc ->
      case returned_callee(instr, next, mod) do
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
    case {register(a), register(b)} do
      {{:x, 0}, _} -> [pattern_of(b) | recv_fail(instrs, l, labels, seen)]
      {_, {:x, 0}} -> [pattern_of(a) | recv_fail(instrs, l, labels, seen)]
      _ -> recv_fail(instrs, l, labels, seen)
    end
  end

  defp recv_head({:select_val, src, {:f, l}, {:list, entries}}, instrs, _idx, labels, seen) do
    if register(src) == {:x, 0},
      do: for({:atom, a} <- entries, do: inspect(a)) ++ recv_fail(instrs, l, labels, seen),
      else: recv_fail(instrs, l, labels, seen)
  end

  defp recv_head({:test, _op, {:f, l}, args}, instrs, _idx, labels, seen) when is_list(args) do
    if Enum.any?(args, &(register(&1) == {:x, 0})),
      do: ["any" | recv_fail(instrs, l, labels, seen)],
      else: recv_fail(instrs, l, labels, seen)
  end

  defp recv_head({:test, _op, {:f, l}, src, _fields}, instrs, _idx, labels, seen) do
    if register(src) == {:x, 0},
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
    if self_origin?(ctx.instrs, ctx.idx, {:x, dest_reg}), do: "self", else: "other"
  end

  # Whether `reg` holds the result of a `self()` call on every path to
  # `idx`, following copies.
  defp self_origin?(instrs, idx, reg) do
    Resolve.trace(instrs, idx, reg, false, fn
      {_at, {:bif, :self, _fail, [], _dst}}, _follow -> true
      _writer, _follow -> false
    end)
  end

  # `:dynamic` is the resolver's placeholder for a value it could not
  # follow — a ref, a counter — and that is what makes a message safe.
  defp bare_message?(:dynamic), do: false
  defp bare_message?(msg) when is_atom(msg) or is_binary(msg) or is_number(msg), do: true

  defp bare_message?(msg) when is_tuple(msg),
    do: msg |> Tuple.to_list() |> Enum.all?(&bare_message?/1)

  # Cell by cell, so an improper list's tail is asked like any element.
  defp bare_message?([]), do: true
  defp bare_message?([head | tail]), do: bare_message?(head) and bare_message?(tail)
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
    {:rpc, :yield, 1},
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
      Instr.tail_call?(Enum.at(instrs, idx)) -> "returned"
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

  defp result_use([{:label, _} | _], _aliases, _instrs), do: "other"

  # Passed to a call (a tail call included), the result is passed on; a
  # call that does not take it clobbers the x registers. A path that ends
  # without examining it — a jump, a raise, a tail call that does not
  # take it — is "other": the walk is linear, and what follows is another
  # path.
  defp result_use([instr | rest], aliases, instrs) do
    cond do
      (Instr.call?(instr) or Instr.tail_call?(instr)) and
          Enum.any?(Instr.uses(instr), &(&1 in aliases)) ->
        "other"

      not Instr.falls_through?(instr) ->
        "other"

      true ->
        result_use(rest, Instr.carry(instr, aliases), instrs)
    end
  end

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
      do: Enum.uniq([register(dst) | aliases]),
      else: List.delete(aliases, register(dst))
  end

  defp alias?(operand, aliases), do: register(operand) in aliases

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
      add_fact(facts, :bare_rescue, [id, ctx.func_id, handler_end(ctx, handler_label, ctx.idx)])
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
      case summary.handled do
        [] ->
          facts

        classes ->
          span_end = handler_end(ctx, handler_label, ctx.idx)

          Enum.reduce(classes, facts, fn class, acc ->
            add_fact(acc, :catch_class, [id, ctx.func_id, to_string(class), span_end])
          end)
      end

    facts =
      Enum.reduce(summary.totals, facts, fn class, acc ->
        add_fact(acc, :catch_total, [id, ctx.func_id, to_string(class)])
      end)

    facts =
      Enum.reduce(summary.tags, facts, fn {class, tag}, acc ->
        add_fact(acc, :catch_tag, [id, ctx.func_id, to_string(class), inspect(tag)])
      end)

    facts =
      Enum.reduce(summary.tuple_tags, facts, fn {class, tag}, acc ->
        add_fact(acc, :catch_tuple_tag, [id, ctx.func_id, to_string(class), inspect(tag)])
      end)

    facts =
      Enum.reduce(summary.falls_through, facts, fn tag, acc ->
        add_fact(acc, :catch_falls_through, [id, ctx.func_id, inspect(tag)])
      end)

    ctx.instrs
    |> Enum.drop(ctx.idx + 1)
    |> Enum.with_index(ctx.idx + 1)
    |> Enum.take_while(fn
      {{:try_end, ^reg}, _} -> false
      {{:try_case, ^reg}, _} -> false
      {{:func_info, _, _, _}, _} -> false
      _ -> true
    end)
    |> Enum.reduce(facts, fn {instr, idx}, acc ->
      case match_remote_call(instr) do
        {:ok, m, f, a} when {m, f, a} in @guarded_calls ->
          add_fact(acc, :try_call, [
            id,
            ctx.func_id,
            Normalize.func_id(m, f, a),
            InstrId.mint(ctx.func_id, idx),
            handler_end(ctx, handler_label, ctx.idx)
          ])

        _ ->
          acc
      end
    end)
  end

  # Erlang's `catch Expr` takes every class: an error or an exit becomes
  # {'EXIT', Reason}, a throw its value. Its handler is the code after
  # `catch_end`, which the normal exit runs too: no span of its own.
  defp maybe_catch_clauses(facts, ctx, {:catch, _reg, {:f, _label}}) do
    add_fact(facts, :catch_class, [InstrId.mint(ctx.func_id, ctx.idx), ctx.func_id, "*", ""])
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
        Instr.tail_call?(instr) ->
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
  # x0 used as argument to the next call (passed forward), in any form:
  # a tail call consumes it just as a plain call does.
  defp result_used?([{:call_ext, _, _} | _]), do: true
  defp result_used?([{:call_ext_only, _, _} | _]), do: true
  defp result_used?([{:call_ext_last, _, _, _} | _]), do: true
  defp result_used?([{:call, _, _} | _]), do: true
  defp result_used?([{:call_only, _, _} | _]), do: true
  defp result_used?([{:call_last, _, _, _} | _]), do: true
  defp result_used?(_), do: false
end
