defmodule Argus.Schema.ErrorHandling do
  @moduledoc """
  Layer-2 facts for exception handlers, result checks, timers, receives, and exit \
  signals. Exposed through `Argus.Schema`.
  """

  @doc "The relations, in the order `Argus.Schema.all/0` lists them."
  @spec relations() :: [Argus.Schema.declaration()]
  def relations do
    Argus.Schema.Reads.record("relations #{__MODULE__}", [
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
        An exception class handled by the try at `id`: some path accepts the class and \
        returns without re-raising. Reason restrictions are allowed. `*` means no class \
        test, including Erlang `catch Expr`, which has no separate span. Re-raise-only \
        handlers have no row.
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
        An exception class caught without restricting its reason. No reason of that \
        class escapes the matching clause.
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
        An atom compared in a handler clause, attributed to its exception class. \
        Includes body comparisons, so it over-approximates handled reason tags. \
        Consumers check for missing tags; extra tags suppress findings.
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
        A tag matched at the head of an exception-reason tuple. Distinguishes `{:noproc, \
        _}` from bare `:noproc` and nested `{{:shutdown, _}, _}`. `*` denotes a clause \
        accepting tuple reasons without testing their elements.
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
        A tag matched at the head of the reason's first tuple element, such as \
        `:shutdown` in `{{:shutdown, _}, _}`. Distinguishes a GenServer call's wrapped \
        shutdown reason from a plain `{:shutdown, _}` reason.
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
        A non-exhaustive `case` in a handler after comparison with `tag`. An unexpected \
        reason raises `CaseClauseError`. The tag distinguishes this case from \
        compiler-generated field-access checks.
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
        A peer call protected by the try, whose failure the handler classifies. The \
        finding anchors at `call` because the try instruction may carry an earlier \
        source line.
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
        A try containing only boundary operations, non-raising instructions, and named \
        calls, including `call`. If every named callee is a `boundary_function`, the try \
        also qualifies as a boundary handler.
        """
      },
      %{
        name: :boundary_function,
        layer: 2,
        fields: [{:func, :symbol, "the function"}],
        doc: """
        A function containing only process-boundary operations and non-raising \
        instructions. Boundary operations include calls, casts, stops, sends, and \
        registrations (`Argus.Extractors.ErrorHandling.Boundary`).
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
        A try protecting only external-state operations and non-raising instructions, or \
        only log construction and emission. A catch-all here handles peer, port, \
        registration, or logging failures rather than errors in arbitrary application \
        code (`Argus.Extractors.ErrorHandling.Boundary`).
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
        A call reachable from the try at `id` before its `try_end`. Nested protected \
        calls belong to both tries; calls in a nested handler belong only to the outer \
        try. `catch_total` and `catch_tag` describe the handler at the same `id`.
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
        Every use of a closure value invokes or passes it to a call within the try's \
        protected region. The closure may be constructed outside the try, but cannot \
        escape through a return, store, or send. Rules separately check whether \
        execution moves to another process; `fun_handed` alone cannot prove exclusive \
        use here.
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
        How an RPC result is used: compared with `:badrpc`, tested as a boolean, matched \
        by shape, matched by wildcard, returned, or passed on unchecked. Shape matching \
        in a function with a clause-less exit may raise on `{:badrpc, _}`; boolean tests \
        treat that tuple as truthy.
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
        How a non-runtime call's result is used when the function never compares with \
        `:badrpc`: shape-matched with a possible clause-less exit, boolean-tested, or \
        returned. Extends `rpc_result` to wrappers. Excludes compiler-generated callees \
        and predicates ending in `?`, whose RPC sites are reported directly.
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
        An armed timer, its destination, and message source: a fixed literal (`bare`), \
        caller parameter (`param`, resolved via `resolved_arg`), or computed value \
        (`dynamic`). Refines `mailbox_writer` timer kinds.
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
        A waiting receive clause's complete message shape: atom, tagged tuple, tuple \
        with a pinned first element, map, arbitrary tuple, or `any`. Unlike \
        `recv_pattern`, reads the whole head. Excludes `after 0` polls \
        (`Argus.Extractors.CallbackTag.MessageClauses.receive_shapes/2`).
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
        An `:erlang.start_timer/3,4` and its destination. `self` requires `self()` on \
        every path. Its `{:timeout, ref, msg}` message carries a reference, so it is \
        excluded from `timer_arm` flush checks.
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
        A timer message's atom tag and arity: 0 for an atom, tuple size otherwise. \
        `:erlang.start_timer/3,4` uses tag `:timeout` and arity 3. Unresolved or other \
        message shapes have no row. Unlike `timer_arm.literal`, this identifies the tag \
        rather than the whole term.
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
        Where a timer reference goes: returned, stored under a literal map key, \
        discarded before any read, or unknown. Discarded references cannot be used to \
        cancel the timer.
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
        The source of a cancelled timer reference: a map field, a parameter resolved \
        through `call_arg_field`, a local `send_after` site, or unknown.
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
        A map update storing a call result under `key`. Combined with `returns_call`, \
        identifies the state field holding a timer reference.
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
        A call to a same-module timer helper whose result is discarded before any read. \
        Follows `returns_call` wrappers to helpers with `timer_ref` value `returned`. \
        The discarded reference cannot be used to cancel the timer.
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
        A test comparing map field `key` with `nil` or `undefined`. Supports checks for \
        timers armed only when no reference is stored.
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
        A test comparing map field `key` with a literal. `field_nil_test` is the subset \
        for `nil` or `undefined`.
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
        A field set in returned state, including maps or records inside callback return \
        tuples. Init sets every field it constructs; an unrecognized replacement state \
        uses key `*`. One row per first-argument clause tag. Used by field-gate and \
        restart-state rules.
        """
      },
      %{
        name: :returned_field_from,
        layer: 2,
        fields: [
          {:func, :symbol, "the function"},
          {:key, :symbol, "a field a return sets, as returned_update spells it"},
          {:site, :symbol, "a call whose answer the field's value is made of"},
          {:how, :symbol,
           "'whole': the answer, or a term that holds it; '{i}': its element i; " <>
             "'part': another piece of it; 'argument': only through another call's arguments"}
        ],
        doc: """
        A returned state field derived from the result of call `site`. Records the whole \
        result, tuple element `{i}`, a deeper `part`, or dependence through another \
        call's `argument`. Local calls follow `returns_from`. Used to locate stored \
        monitor records and removal results (`Argus.Extractor.StateFields`).
        """
      },
      %{
        name: :returns_from,
        layer: 2,
        fields: [
          {:func, :symbol, "the function"},
          {:site, :symbol, "a call in it whose answer what it returns is made of"}
        ],
        doc: """
        A return containing all or part of call `site`'s result. Includes tail calls \
        and, for remote tail calls, their arguments. Traces results through helpers; \
        `returned_field_from` identifies the caller's storage field.
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
        A function returning a callee's result, by tail call or a subsequent return. \
        Supports chains of result-forwarding wrappers.
        """
      },
      %{
        name: :answers_call,
        layer: 2,
        fields: [
          {:func, :symbol, "the function"},
          {:site, :symbol, "a call in it whose answer a return hands back"},
          {:depth, :number,
           "0: the answer itself, or its payload re-wrapped under a literal tag; " <>
             "1: the answer's payload (the pid of an `{:ok, pid}`)"}
        ],
        doc: """
        Every non-raising return forwards a listed call's result, its immediate payload, \
        or that payload rewrapped. Any unrelated return or deeper extraction removes all \
        rows for the function. This is the must-return counterpart of `returns_call`; \
        `clientlib/answers.dl` chains it through wrappers (`Argus.Extractor.Answers`).
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
        A receive clause's literal atom pattern, or `any` for other patterns. Used to \
        check whether a flush after `cancel_timer/1` accepts the timer message.
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
        A cancellation inside a `handle_info/2` clause for a literal atom, with the head \
        test dominating the call and the message argument unchanged. A timer for this \
        message has already fired.
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
        A callback clause accepting a tuple headed by a reference, such as the `{ref, \
        result}` reply from an `async_nolink` task.
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
        A call that can introduce non-request messages into the caller's mailbox, \
        including task replies, `:DOWN`, timers, subscription broadcasts, and \
        self-sends.
        """
      },
      %{
        name: :trap_exit,
        layer: 2,
        fields: [
          {:id, :instr_id, "the call"},
          {:func, :symbol, "containing function ID"},
          {:mod, :symbol, "module name"}
        ],
        doc: """
        A literal `trap_exit: true` process-flag call. Later sites can be ordered with \
        `site_block` and `clientlib/trapping.dl`. Computed flag values have no row.
        """
      },
      %{
        name: :untrap_exit,
        layer: 2,
        fields: [
          {:id, :instr_id, "the call"},
          {:func, :symbol, "containing function ID"},
          {:mod, :symbol, "module name"}
        ],
        doc: """
        A literal `trap_exit: false` process-flag call. Computed values, including \
        restoration of an earlier flag value, use `trap_flag_unread` instead.
        """
      },
      %{
        name: :trap_flag_unread,
        layer: 2,
        fields: [
          {:id, :instr_id, "the call"},
          {:func, :symbol, "containing function ID"},
          {:mod, :symbol, "module name"}
        ],
        doc: """
        A process-flag call with unresolved `trap_exit` value. Establishes `may_trap` \
        but does not prove trapping is enabled, so unknown values cannot be treated as \
        defaults.
        """
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
