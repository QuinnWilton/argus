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
    [
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
          {:tag, :symbol, "an atom the clause compares as a tuple's first element"}
        ],
        doc: """
        The `catch_tag` rows whose atom heads a tuple the clause tests for: \
        an `is_tagged_tuple`, or a comparison on a register holding a tuple's \
        first element. `catch :exit, {:noproc, _}` has one; `catch :exit, \
        :noproc`, which compares the reason itself, has only the `catch_tag` \
        row. A `GenServer.call` to a dead process exits with \
        `{:noproc, {GenServer, :call, _}}` and a `GenServer.stop` with bare \
        `:noproc`, so the two forms catch different exits.
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
        name: :timer_ref,
        layer: 2,
        fields: [
          {:id, :symbol, "the send_after / send_interval site"},
          {:func, :symbol, "the function"},
          {:flow, :symbol, "'returned' | 'stored' | 'dynamic'"},
          {:key, :symbol, "the inspected map key the ref is stored under, else ''"}
        ],
        doc: """
        Where the ref of the timer armed at `id` goes: returned by the \
        function (an arming helper), stored under a literal key of a map \
        (`%{state | timer: ...}`, `Map.put(state, :timer, ...)`), or \
        somewhere the walk cannot follow.
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
           "'task' | 'task_nolink' | 'timer' | 'timer_bare' | 'cancel' | 'pubsub' | 'self' | 'apply'"}
        ],
        doc: """
        A call after which something other than a peer's request can land in \
        the calling process's mailbox: a Task.async reply, a timer message, a \
        subscription's broadcasts, a message the function sends to itself, \
        or caller-supplied code run through a closure or apply. What makes a \
        partial handle_info/2 a risk rather than a style note.
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
    ]
  end
end
