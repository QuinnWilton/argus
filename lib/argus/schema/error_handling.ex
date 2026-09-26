defmodule Argus.Schema.ErrorHandling do
  @moduledoc """
  How a module handles failure: its rescues and catches, the results it
  checks or ignores, the timers it arms and cancels, the messages it can
  find in its mailbox, and the exits it traps or sends.

  Layer 2 of `Argus.Schema`, which reads the relations from here.
  """

  @doc "The relations, in the order `Argus.Schema.all/0` lists them."
  @spec relations() :: [Argus.Schema.declaration()]
  def relations do
    Argus.Cache.Reads.record("relations #{__MODULE__}", [
      %{
        name: :bare_rescue,
        layer: 2,
        fields: [
          {:id, :symbol, "instruction ID of try_start"},
          {:func, :symbol, "containing function ID"},
          {:guard_end, :symbol, "the handler's own last line marker, else empty"}
        ],
        doc: "Try/catch handler that catches all exceptions without filtering or reraising."
      },
      %{
        name: :catch_class,
        layer: 2,
        fields: [
          {:id, :symbol, "the try (or catch) instruction"},
          {:func, :symbol, "the function"},
          {:class, :symbol, "a class the handler takes: 'error' | 'exit' | 'throw' | '*'"},
          {:span_end, :symbol, "the handler's own last line marker; empty for a catch or none"}
        ],
        doc: """
        The handler of the try at `id` takes `class`: some path through it \
        establishes the class and returns without raising again, whatever \
        it asks of the reason. A handler that only re-raises (`after`, \
        `rescue e -> reraise e, __STACKTRACE__`) has no row; `*` is a path \
        with no class test. Erlang's `catch Expr` takes every class: one \
        row, `*`, and no span of its own.
        """
      },
      %{
        name: :catch_total,
        layer: 2,
        fields: [
          {:id, :symbol, "the try instruction"},
          {:func, :symbol, "the function"},
          {:class, :symbol, "the class caught without a pattern on the reason"}
        ],
        doc: """
        Some clause of the handler catches the class outright — `catch :exit, \
        reason ->`, `rescue e ->` — so no reason of that class escapes it.
        """
      },
      %{
        name: :catch_tag,
        layer: 2,
        fields: [
          {:id, :symbol, "the try instruction"},
          {:func, :symbol, "the function"},
          {:class, :symbol, "the class the clause catches: 'error' | 'exit' | 'throw' | '*'"},
          {:tag, :symbol, "an atom the clause compares against; the struct name for `rescue X`"}
        ],
        doc: """
        A reason tag a clause discriminates on, attributed to the class that \
        clause catches. Within a clause every compared atom counts (a `case` \
        in the body too), the over-approximation `callback_tag` makes: rules \
        ask whether a tag is NOT handled, so seeing too many suppresses \
        findings rather than inventing them.
        """
      },
      %{
        name: :catch_tuple_tag,
        layer: 2,
        fields: [
          {:id, :symbol, "the try instruction"},
          {:func, :symbol, "the function"},
          {:class, :symbol, "the class the clause catches: 'error' | 'exit' | 'throw' | '*'"},
          {:tag, :symbol,
           "an atom the clause compares as a tuple's first element; * for any tuple"}
        ],
        doc: """
        The `catch_tag` rows whose atom heads the reason, a tuple the clause \
        tests for: an `is_tagged_tuple` of the reason, or a comparison on a \
        register holding the reason's first element. `catch :exit, \
        {:noproc, _}` has one; `catch :exit, :noproc`, which compares the \
        reason itself, has only the `catch_tag` row, and `catch :exit, \
        {{:shutdown, _}, _}`, which heads a tuple inside it, a \
        `catch_inner_tag` one. A `GenServer.call` to a dead process exits with \
        `{:noproc, {GenServer, :call, _}}` and a `GenServer.stop` with bare \
        `:noproc`, so the two forms catch different exits. A clause that \
        takes any tuple reason by its shape alone, never comparing its \
        elements (`catch exit:{Reason, _}`), is the tag `*`: it takes \
        `{:shutdown, _}` and `{:normal, _}` too.
        """
      },
      %{
        name: :catch_inner_tag,
        layer: 2,
        fields: [
          {:id, :symbol, "the try instruction"},
          {:func, :symbol, "the function"},
          {:class, :symbol, "the class the clause catches: 'error' | 'exit' | 'throw' | '*'"},
          {:tag, :symbol,
           "an atom the clause compares as the first element of the reason's first element"}
        ],
        doc: """
        The `catch_tag` rows whose atom heads the reason's first element, \
        itself a tuple: `catch :exit, {{:shutdown, _}, _}` has `:shutdown`. \
        A `GenServer.call` whose peer stops with `{:shutdown, reason}` \
        while the call waits exits with `{{:shutdown, reason}, {GenServer, \
        :call, _}}`, which a clause for `{:shutdown, _}` (a `catch_tuple_tag`, \
        the peer's bare `:shutdown`) does not take.
        """
      },
      %{
        name: :catch_falls_through,
        layer: 2,
        fields: [
          {:id, :symbol, "the try instruction"},
          {:func, :symbol, "the function"},
          {:tag, :symbol, "an atom compared on the path to the case"}
        ],
        doc: """
        A `case` inside the handler, reached after comparing `tag`, has no \
        clause for some value: a reason the handler did not anticipate is a \
        CaseClauseError rather than a result. The tag identifies the case — \
        the compiler emits a clause-less case of its own for `e.field`.
        """
      },
      %{
        name: :try_call,
        layer: 2,
        fields: [
          {:id, :symbol, "the try instruction"},
          {:func, :symbol, "the function"},
          {:callee, :func_id, "the guarded call (Mod:fun/arity)"},
          {:call, :instr_id, "the guarded call's own instruction"},
          {:guard_end, :symbol,
           "the handler's last instruction: where a span over the catch ends"}
        ],
        doc: """
        A peer call the try guards — GenServer.call, :gen_statem.call, \
        :erpc.call and their kin — whose failure the handler is expected to \
        classify. `call` is where a finding points: the try instruction \
        carries the line of whatever preceded it.
        """
      },
      %{
        name: :try_wrapper_call,
        layer: 2,
        fields: [
          {:id, :symbol, "the try (or catch) instruction"},
          {:func, :symbol, "the function"},
          {:call, :symbol, "a call the try protects that is no boundary operation itself"}
        ],
        doc: """
        The try at `id` protects only boundary operations (as \
        `try_boundary` names them), instructions that cannot raise, and \
        calls to named functions, `call` being one of those calls: if \
        every such callee is a `boundary_function`, the try is a boundary \
        one hop away (hackney's `try hackney_conn:stop(Pid) catch _:_ -> \
        ok end`).
        """
      },
      %{
        name: :boundary_function,
        layer: 2,
        fields: [{:func, :symbol, "the function"}],
        doc: """
        A function whose body is boundary operations (a call, cast or stop \
        of another process, a send, a registration) and instructions that \
        cannot raise: a client API such as `stop(Pid) -> \
        gen_statem:stop(Pid)` (`Argus.Extractors.ErrorHandling.Boundary`).
        """
      },
      %{
        name: :try_boundary,
        layer: 2,
        fields: [
          {:id, :symbol, "the try (or catch) instruction"},
          {:func, :symbol, "the function"}
        ],
        doc: """
        The try at `id` protects only operations whose failure is another \
        process's, a port's or a name's state — a send, an exit signal, a \
        call into another process or node, a registration, a named \
        `:ets.new` — and instructions that cannot raise; or only the \
        building and emitting of a log line \
        (`Argus.Extractors.ErrorHandling.Boundary`). A catch-all around it \
        takes a dead peer, a taken name or a failed log handler, not a bug \
        in the code it guards.
        """
      },
      %{
        name: :try_covers,
        layer: 2,
        fields: [
          {:id, :symbol, "the try (or catch) instruction"},
          {:func, :symbol, "the function"},
          {:call, :instr_id, "a call inside its protected region"},
          {:kind, :symbol, "'try' | 'catch' (Erlang's `catch Expr`, which takes every class)"}
        ],
        doc: """
        The try at `id` covers the call at `call`: the call is on a path \
        from the try that has not passed its `try_end`, so what it raises \
        goes to that try's handler, whose classes and reasons are \
        catch_total and catch_tag at the same `id`. Walked on the \
        function's control-flow graph: a call after the try's `end` is not \
        covered, a call inside a nested try is covered by both, and a call \
        in a nested try's handler by the outer one alone.
        """
      },
      %{
        name: :try_covers_closure,
        layer: 2,
        fields: [
          {:id, :symbol, "the try (or catch) instruction"},
          {:func, :symbol, "the function"},
          {:closure, :func_id, "a closure whose value only calls inside the region read"}
        ],
        doc: """
        Every read of the closure's value in the function is a call inside \
        the try's protected region: it is handed to `Enum.each` there, or \
        called, and not returned, stored or sent. Where the closure is built \
        does not matter; the compiler hoists one with nothing to capture \
        out of the try. Whether the call it is handed to runs it in another \
        process is the rules' question. `fun_handed` names the calls a fun is \
        handed to, but has no row for a fun returned, stored or called \
        through a variable, so it cannot say the fun runs nowhere else.
        """
      },
      %{
        name: :rpc_result,
        layer: 2,
        fields: [
          {:id, :symbol, "the rpc call site"},
          {:func, :symbol, "the function"},
          {:handling, :symbol, "'badrpc' | 'boolean' | 'case' | 'matched' | 'returned' | 'other'"}
        ],
        doc: """
        How the result of an :rpc.call / :rpc.multicall / :erpc.call is \
        treated: compared to :badrpc somewhere in the function; tested as a \
        boolean (where a {:badrpc, _} tuple is truthy); matched by shape in a \
        function with a clause-less exit (a CaseClauseError or MatchError on \
        {:badrpc, _}); matched with a wildcard; returned as the function's own \
        result; or stored or passed on unexamined.
        """
      },
      %{
        name: :result_tested,
        layer: 2,
        fields: [
          {:id, :instr_id, "the call"},
          {:func, :func_id, "the function making it"},
          {:callee, :func_id, "what it calls (Mod:fun/arity)"},
          {:how, :symbol, "'case' | 'boolean' | 'returned'"}
        ],
        doc: """
        What a function that compares nothing to :badrpc does with a call's \
        result: matches it by shape where the function has a clause-less \
        exit (`case`: an answer no clause takes raises), tests it against \
        true/false/nil (`boolean`), or returns it as its own result \
        (`returned`: a tail call, or the result in x0 at a return), local \
        and remote callees alike. `rpc_result` says the same of an rpc \
        API's own sites; this is what a caller does with a function that \
        returns an rpc's answer. Calls into the runtime \
        (`Argus.Extractor.Runtime`), to a function the compiler made, and \
        to a predicate (a name ending in `?`, whose rpc is reported where \
        it is made) are not rows.
        """
      },
      %{
        name: :timer_arm,
        layer: 2,
        fields: [
          {:id, :symbol, "the send_after / send_interval site"},
          {:func, :symbol, "the function"},
          {:target, :symbol, "'self' | 'other'"},
          {:message, :symbol, "'bare' | 'param' | 'dynamic'"},
          {:param, :number, "the parameter position when message is 'param', else -1"},
          {:literal, :symbol, "the inspected message when it is 'bare', else ''"}
        ],
        doc: """
        A timer armed at `id`: whether it targets the arming process, and \
        whether its message is a literal that cannot be told from an earlier \
        instance of itself ('bare'), one of the function's own parameters \
        ('param', with its position, for a rule to resolve at the callers \
        through resolved_arg), or a computed value such as a ref \
        ('dynamic'). Refines the `timer` / `timer_bare` kinds of \
        mailbox_writer.
        """
      },
      %{
        name: :recv_shape,
        layer: 2,
        fields: [
          {:id, :symbol, "the receive (its loop_rec)"},
          {:func, :symbol, "the function it is in"},
          {:shape, :symbol,
           "':atom' | '{:tag, …}' | '{ref, …}' | 'map' | 'tuple' | 'any': what a clause takes"}
        ],
        doc: """
        The shape a clause of the receive at `id` takes the message in, \
        read on its head as a callback's clauses are \
        (`Argus.Extractors.CallbackTag.MessageClauses.receive_shapes/2`): \
        the atom itself, a tuple with a literal atom tag (`{:tag, …}`), a \
        tuple whose first element is compared with a value the function \
        holds — a ref it made, a pid it was handed — (`{ref, …}`), a map, a \
        tuple of any tag (`tuple`), or anything (`any`). recv_pattern reads \
        each clause's first test only; this is the whole head. Only for a \
        receive that waits, forever or with an `after`: an `after 0` poll \
        takes what is already there and is no row.
        """
      },
      %{
        name: :start_timer_arm,
        layer: 2,
        fields: [
          {:id, :symbol, "the :erlang.start_timer/3,4 site"},
          {:func, :symbol, "the function arming it"},
          {:target, :symbol, "'self' when it arms the calling process, else 'other'"}
        ],
        doc: """
        An `:erlang.start_timer/3,4` at `id`, and whose mailbox its \
        `{:timeout, ref, msg}` lands in: `self` when the destination is the \
        result of `self()` on every path, as timer_arm reads a send_after's. \
        The flush rules do not ask of it (its message carries the ref), so \
        it is no timer_arm.
        """
      },
      %{
        name: :timer_tag,
        layer: 2,
        fields: [
          {:id, :symbol, "the send_after / send_interval / start_timer site"},
          {:tag, :symbol, "the inspected atom"},
          {:arity, :number, "0 when the message is the atom, else the tuple's size"}
        ],
        doc: """
        The atom the message of the timer armed at `id` is told apart by, \
        as a clause head or a receive compares it: the message itself when \
        it is an atom, or the first element of a tuple — a literal one \
        (`{:warm_up, 5}`) or one the arming site builds \
        (`{:retry, attempts - 1}`) — with the message's `arity`: 0 for \
        the atom, the tuple's size otherwise. `:erlang.start_timer/3,4`'s \
        is `:timeout`, 3: it sends `{:timeout, ref, msg}`. No row when the \
        message is anything else or does not resolve. A literal tuple's \
        `literal` in timer_arm spells the whole term, which no tag equals.
        """
      },
      %{
        name: :timer_ref,
        layer: 2,
        fields: [
          {:id, :symbol, "the send_after / send_interval site"},
          {:func, :symbol, "the function"},
          {:flow, :symbol, "'returned' | 'stored' | 'discarded' | 'dynamic'"},
          {:key, :symbol, "the inspected map key the ref is stored under, else ''"}
        ],
        doc: """
        Where the ref of the timer armed at `id` goes: returned by the \
        function (an arming helper), stored under a literal key of a map \
        (`%{state | timer: ...}`, `Map.put(state, :timer, ...)`), dropped \
        on the spot — every register holding it overwritten before any \
        instruction reads it (`send_after(...)` then `{:noreply, state}`), \
        so nothing can cancel the timer — or somewhere the walk cannot \
        follow (a record, a tuple, another path).
        """
      },
      %{
        name: :timer_cancel,
        layer: 2,
        fields: [
          {:id, :symbol, "the cancel_timer site"},
          {:func, :symbol, "the function"},
          {:source, :symbol, "'field' | 'param' | 'local' | 'dynamic'"},
          {:key, :symbol,
           "the inspected map key the ref was read from; for 'local', the arming site; else ''"},
          {:param, :number, "the parameter position when source is 'param', else -1"}
        ],
        doc: """
        Where the ref cancelled at `id` came from: a map field read in the \
        function (`state.timer`, a `%{timer: ref}` head), one of the \
        function's parameters (resolved at the callers through \
        call_arg_field), the ref a send_after in the same function returned \
        ('local', keyed by that site), or unknown.
        """
      },
      %{
        name: :timer_store,
        layer: 2,
        fields: [
          {:func, :symbol, "the function"},
          {:key, :symbol, "the inspected map key"},
          {:callee, :symbol, "the function whose result is stored"}
        ],
        doc: """
        A map update in `func` stores the result of a call to `callee` under \
        `key`: `%{state | timer: arm(ms)}`. With returns_call this ties a \
        timer ref to the state field that keeps it.
        """
      },
      %{
        name: :timer_dropped,
        layer: 2,
        fields: [
          {:site, :symbol, "the call"},
          {:func, :symbol, "the function making it"},
          {:callee, :symbol, "the arming helper of the module it calls"}
        ],
        doc: """
        The call at `site` is to a function of the module that returns a \
        timer's ref (timer_ref "returned", or a wrapper returning such a \
        function's result, returns_call), and `func` drops the result on the \
        spot: every register holding it is overwritten before any \
        instruction reads it. Nothing can cancel that timer, as with a \
        send_after whose own function drops its ref ("discarded").
        """
      },
      %{
        name: :field_nil_test,
        layer: 2,
        fields: [
          {:func, :symbol, "the function"},
          {:key, :symbol, "the inspected map key"}
        ],
        doc: """
        `func` tests the map field under `key` against nil or undefined: \
        a clause head `%{receive_timer: nil}`, an `if state.timer == nil`, \
        an Erlang map pattern `tref := undefined`. A function that arms a timer only \
        when the field keeping its ref is empty arms none beside a pending \
        one (a Broadway producer's receive loop).
        """
      },
      %{
        name: :field_value_test,
        layer: 2,
        fields: [
          {:func, :symbol, "the function"},
          {:key, :symbol, "the inspected map key"},
          {:value, :symbol, "the literal atom or integer it is compared with, inspected"}
        ],
        doc: """
        `func` tests the map field under `key` for equality with a literal \
        (nil among them): a clause head `%{draining: true}`, an `if \
        state.mode == :idle`, a `case` arm. field_nil_test is the nil half, \
        read alone where only an empty field matters.
        """
      },
      %{
        name: :returned_update,
        layer: 2,
        fields: [
          {:func, :symbol, "the function"},
          {:key, :symbol,
           "the inspected map key, an Erlang record's field as its 0-based tuple position ({2}), " <>
             "or * for a whole state the fields do not spell"},
          {:value, :symbol, "the literal it is set to, inspected, or 'dynamic'"},
          {:tag, :symbol,
           "the tag of the clause the return is in, as clause_call spells it, or * for a return every clause shares"}
        ],
        doc: """
        What `func` returns sets the field under `key`: of the returned \
        map or record, or of one an element of the returned tuple holds — \
        a callback's `{:noreply, [], %{state | receive_timer: nil}}`, an \
        Erlang `{noreply, State#state{subs = Subs}}`. The state an init/1 \
        builds whole (the element after `ok` in `{ok, State}`) sets every \
        field it has; a callback's state that is neither the one it was \
        given nor one these fields spell (`maps:put/3`'s result) sets the \
        whole state, key `*`. One row per clause the return is in, by the \
        tag of the first argument (Dispatch.argument_tags/2). The state a \
        callback hands back, where field_nil_test is what a clause head \
        needs of it and clientlib/restart_state.dl what a restart takes \
        back.
        """
      },
      %{
        name: :returns_call,
        layer: 2,
        fields: [
          {:func, :symbol, "the function"},
          {:callee, :symbol, "the function whose result it returns"}
        ],
        doc: """
        `func` returns the result of a call to `callee`: a tail call, or a \
        call followed by return. The chain `defp arm(ms), do: \
        Process.send_after(...)` is one hop; default-argument wrappers add \
        more.
        """
      },
      %{
        name: :recv_pattern,
        layer: 2,
        fields: [
          {:id, :symbol, "the receive's loop_rec"},
          {:func, :symbol, "the function"},
          {:message, :symbol, "an inspected atom a clause matches, or 'any'"}
        ],
        doc: """
        What a receive matches, one row per clause: a literal atom, or 'any' \
        for a clause whose pattern is not an atom (a tuple, a wildcard, a \
        guard on the message). Says whether a flush after cancel_timer/1 \
        takes the timer's own message.
        """
      },
      %{
        name: :cancel_clause,
        layer: 2,
        fields: [
          {:id, :symbol, "the cancel_timer site"},
          {:func, :symbol, "the handle_info/2 holding it"},
          {:message, :symbol, "the inspected atom the clause's head matches"}
        ],
        doc: """
        A cancel_timer inside a `handle_info/2` clause whose head is a literal \
        message: `def handle_info(:heartbeat, s)` — the head test on the \
        first argument dominates the cancel, and nothing before it overwrote \
        the argument. Cancelling the timer whose message this clause is \
        handling cancels a timer that has already fired.
        """
      },
      %{
        name: :callback_ref_head,
        layer: 2,
        fields: [
          {:func, :symbol, "the callback"},
          {:callback, :symbol, "'handle_call' | 'handle_cast' | 'handle_info'"}
        ],
        doc: """
        The callback has a clause whose message is a tuple headed by a \
        reference — `{ref, result} when is_reference(ref)`, the reply of a \
        task started with async_nolink.
        """
      },
      %{
        name: :mailbox_writer,
        layer: 2,
        fields: [
          {:id, :symbol, "the call site"},
          {:func, :symbol, "the function"},
          {:kind, :symbol,
           "'task' | 'task_nolink' | 'timer' | 'timer_bare' | 'cancel' | 'pubsub' | 'self'"}
        ],
        doc: """
        A call after which something other than a peer's request can land in \
        the calling process's mailbox: a Task.async reply, an async_nolink \
        task's reply and :DOWN, a timer message, a subscription's \
        broadcasts, a message the function sends to itself.
        """
      },
      %{
        name: :trap_exit,
        layer: 2,
        fields: [
          {:func, :symbol, "containing function ID"},
          {:mod, :symbol, "module name"}
        ],
        doc: "Process.flag(:trap_exit, true) call site."
      },
      %{
        name: :exit_call,
        layer: 2,
        fields: [
          {:id, :symbol, "instruction ID"},
          {:func, :symbol, "containing function ID"},
          {:target, :symbol, "exit target (pid or dynamic)"}
        ],
        doc: "Explicit Process.exit/2 or :erlang.exit/1,2 call."
      },
      %{
        name: :ignored_error_result,
        layer: 2,
        fields: [
          {:id, :symbol, "instruction ID"},
          {:func, :symbol, "containing function ID"},
          {:callee, :symbol, "called function returning {:ok,_}|{:error,_}"}
        ],
        doc: "Call to function returning tagged tuple where result is not pattern matched."
      }
    ])
  end
end
