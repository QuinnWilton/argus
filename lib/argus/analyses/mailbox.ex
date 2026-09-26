defmodule Argus.Analyses.Mailbox do
  @moduledoc """
  A message arrives and nothing takes it, or takes it wrongly.

  A process's mailbox is written by more than its owner. Every finding
  here is a message and the clause that is not there for it, or a reply
  a caller waits for that never comes.

  - `unhandled_timeout(mod, state, kind)` — a gen_statem timeout armed in
    `state` (a state function's name, or `handle_event`) whose event type
    (`event_timeout`, `generic_timeout`, `state_timeout`) no clause of the
    machine takes.
  - `task_result_defect(func, site, kind)` — a `Task.async`
    `never_awaited`, `yield_linked` (collected with `Task.yield` in a
    process that does not trap exits) or `linked_in_library` (started in
    library code that links it to an unknown caller).
  - `monitor_leak(mod, func, site, how)` — a monitor that code which runs
    again takes again before the one before it is released: a `wait`
    that returns with it live, a record the server drops while it keeps
    the monitor (`ended`), a ref thrown away by a run that does not ask
    its state first (`dropped`). See `docs/design/monitor-leaks.md`.
  - `timer_cancel_without_flush(mod, cancel, arm, key, message,
    cancel_site, arm_site)` — a
    cancelled timer's message may already be queued and is not told
    apart from the next. The ref is kept under a state key, or (`key`
    empty) in a local of the one function that arms and cancels it.
  - `reply_defect(mod, func, site, kind, tag)` — a tag the module sends
    its own server with no matching clause (`unhandled_call`,
    `unhandled_cast`), a `handle_call` that defers a reply without keeping `from`
    (`dropped_from`), or a `{:call, from}` clause that never answers
    (`statem_unreplied`).
  - `unreceived_message(mod, func, site, message, runs, starter, spawn, recv)` —
    a send that process points-to follows to a spawned process none of
    whose receives (the spawned function's, and those of what it calls in
    its own process) has a clause for `message`: it stays in that
    mailbox, and every later receive scans past it.
  - `unhandled_info(mod, func, site, message, source, server, handler, fallback)` —
    a message a GenServer is sent (`source`: a `send` process points-to
    follows to it, a `timer` it arms for itself, the `:DOWN` of a
    `monitor` it takes, the close of a `socket` it makes active —
    `{:tcp_closed, …}` or `{:ssl_closed, …}` — the events of the `node`
    monitoring it turns on, the output of a `port` it opens, the reply
    and the `:DOWN` of a `task` it starts with async_nolink and does not
    collect, what a `late` timed receive leaves behind: the reply of a
    process it spawns, an event of a subscription it makes, the `exit`
    of a process it links while it traps exits) that no clause of its
    handle_info/2 takes:
    `fallback` says what does instead — nothing (`crash`, a
    FunctionClauseError), a `catch_all` that only logs or ignores it, or
    GenServer's `default` handle_info/2, which logs it as an error; or,
    sent to a gen_statem none of whose callbacks takes it, a state with no
    `:info` catch-all (`state_crash`, `handler` is that state's function).
  - `static_render_registration(mod, entry, func, site, kind)` — a
    LiveView callback that also runs on the static render (`mount/3`,
    `handle_params/3`, a LiveComponent's `mount/1` and `update/2`, an
    `on_mount/4` hook) reaches, in its own process and with no
    `connected?/1` test in the way, a registration for later messages
    (`kind` `subscribe`, `timer` to self, `monitor`): on the static render
    it registers the HTTP connection's process.
  - `repeated_subscription(mod, entry, func, site)` — a callback that runs
    again and again (a handler, `handle_params/3`, `handle_event/3`, a
    channel's `handle_in/3`) reaches a subscription (PubSub, an
    endpoint's, `:pg`), and nothing the module's callbacks run ever
    unsubscribes: each run adds one more copy of every later broadcast.
  """

  @behaviour Argus.Analysis

  alias Argus.Findings

  @impl true
  def name, do: :mailbox

  @impl true
  def description, do: "messages that arrive with no clause for them, and replies that never come"

  @impl true
  def rules_file, do: "analyses/mailbox.dl"

  @impl true
  def extractors,
    do: [
      Argus.Extractors.ErrorHandling,
      Argus.Extractors.OTP,
      Argus.Extractors.CallArgs,
      Argus.Extractors.ApiCalls,
      Argus.Extractors.CallbackTag,
      Argus.Extractors.Monitor,
      Argus.Extractors.GenStatem,
      Argus.Extractors.Reply,
      # Where a send goes: process points-to (clientlib/processes.dl,
      # sends.dl), and the names servers are started under.
      Argus.Extractors.PidFlow,
      Argus.Extractors.ProcessRegistry,
      # A GenServer a child spec names is a server process too.
      Argus.Extractors.Supervision,
      # Which handle_info/2 is GenServer's own (unhandled_info's "default").
      Argus.Extractors.Generated,
      # The sockets a server makes active (unhandled_info's "socket").
      Argus.Extractors.Sockets,
      # Which clause of handle_info/2 a call runs in (clause_call): a
      # periodic timer loop is the clause for its own message.
      Argus.Extractors.ClauseCall,
      # Where a LiveView asks connected?/1 (connected_guarded).
      Argus.Extractors.LiveView,
      # The rows a server writes and deletes (ets_op): a monitored process's
      # record in a table, dropped while its monitor stays (monitor_leak).
      Argus.Extractors.ETS,
      # A protocol's dispatch (protocol_dispatch): a call the call graph
      # does not follow, through which code no known root reaches can run
      # on a process's stack (clientlib/runs.dl, opaque_stack).
      Argus.Extractors.Purity,
      Argus.Extractors.Tooling
    ]

  @impl true
  def output_relations do
    [
      %{
        name: :unhandled_timeout,
        fields: [
          {:mod, :symbol, "the gen_statem module"},
          {:state, :symbol, "the state function arming the timeout, or 'handle_event'"},
          {:kind, :symbol, "event_timeout | generic_timeout | state_timeout"}
        ],
        # One finding per module and timeout kind.
        key: [:mod, :kind],
        doc: "A gen_statem timeout armed whose event type no clause takes."
      },
      %{
        name: :timer_cancel_without_flush,
        fields: [
          {:mod, :symbol, "the process module"},
          {:cancel, :symbol, "function cancelling the timer"},
          {:arm, :symbol, "function arming a timer whose message carries no ref"},
          {:key, :symbol,
           "the state key holding the timer ref, or '' for a ref the function keeps in a local"},
          {:message, :symbol, "the timer's message"},
          {:cancel_site, :symbol, "the cancel_timer call"},
          {:arm_site, :symbol, "the send_after that arms it"}
        ],
        # A local ref has no state key: its arming site is the timer.
        key: {:key, %{"" => [:mod, :arm_site], :default => [:mod, :key]}},
        doc: "A cancelled timer's message may already be in the mailbox and is not told apart."
      },
      %{
        name: :timer_loop_rearmed,
        fields: [
          {:mod, :symbol, "the server module"},
          {:message, :symbol, "the literal message the loop's timer carries"},
          {:entry, :symbol, "the callback that arms the loop again"},
          {:site, :symbol, "where the callback arms it, or makes the call that does"},
          {:arm_site, :symbol, "the send_after, or the send to self(), that arms it"},
          {:loop_site, :symbol, "the send_after the loop's own clause re-arms with"},
          {:keeps, :symbol,
           "the state key the loop keeps its ref under, or '' when the loop drops it"}
        ],
        # One per place a callback arms the loop again, however many of
        # the loop's re-arms it multiplies.
        key: [:mod, :message, :site],
        doc: "A periodic timer loop that another callback arms again while it runs."
      },
      %{
        name: :static_render_registration,
        fields: [
          {:mod, :symbol, "the LiveView (or LiveComponent, or on_mount hook) module"},
          {:entry, :symbol, "the callback that runs on the static render too"},
          {:func, :symbol, "the function making the registration"},
          {:site, :symbol, "the subscription, timer or monitor"},
          {:kind, :symbol, "subscribe | timer | monitor"}
        ],
        # One per registration, whichever callbacks of the module reach it.
        key: [:mod, :site],
        doc:
          "A LiveView callback that runs on the static render registers the process " <>
            "for later messages without asking connected?/1."
      },
      %{
        name: :repeated_subscription,
        fields: [
          {:mod, :symbol, "the process module"},
          {:entry, :symbol, "a callback that runs again and again and reaches it"},
          {:func, :symbol, "the function subscribing"},
          {:site, :symbol, "the subscription"}
        ],
        # One per subscription and module, whichever callbacks reach it.
        key: [:mod, :site],
        doc:
          "A callback that runs again and again subscribes the process each time, " <>
            "and the module never unsubscribes."
      },
      %{
        name: :timer_cancel_under_test,
        fields: [
          {:mod, :symbol, "the process module"},
          {:key, :symbol, "the state key holding the timer ref"},
          {:site, :symbol, "a cancel_timer call on a path only the tests take"},
          {:func, :symbol, "the function it is in"}
        ],
        key: [:mod, :key, :site],
        evidence: %{of: :timer_cancel_without_flush, on: [:mod, :key], limit: 3},
        doc:
          "Where a timer is also cancelled, on a path only the program's tests take, " <>
            "attached to the finding anchored where the program itself cancels it."
      },
      %{
        name: :unreceived_message,
        fields: [
          {:mod, :symbol, "the sending module"},
          {:func, :symbol, "the sending function"},
          {:site, :symbol, "the send"},
          {:message, :symbol, "the literal atom, or {:tag, …}"},
          {:runs, :symbol, "the function the receiving process runs"},
          {:starter, :symbol, "the function that spawned it"},
          {:spawn, :symbol, "the spawn"},
          {:recv, :symbol, "its receive"}
        ],
        key: [:site, :runs],
        doc: "A message sent to a spawned process whose receive has no clause for it."
      },
      %{
        name: :unhandled_info,
        fields: [
          {:mod, :symbol, "the sending module"},
          {:func, :symbol,
           "the function that sends, arms the timer, monitors, makes the socket active, " <>
             "turns on node monitoring, opens the port, starts the task, waits or links"},
          {:site, :symbol,
           "the send, the timer, the monitor, the socket's activation, the node " <>
             "monitoring, the port's open, the task's start, the timed receive or the link"},
          {:message, :symbol,
           "the literal atom, {:tag, …}, {:DOWN, …}, {:tcp_closed, …}, {:ssl_closed, …}, " <>
             "{:nodeup, …}, {:nodedown, …}, {port, {:data, …}}, {ref, …}, {:EXIT, …}, " <>
             "map or tuple"},
          {:source, :symbol,
           "send | timer | monitor | socket | node | port | task | late | exit"},
          {:server, :symbol, "the GenServer module whose handle_info/2 it reaches"},
          {:handler, :symbol, "its handle_info/2, or the gen_statem state function"},
          {:fallback, :symbol, "crash | catch_all | default | state_crash"}
        ],
        # A socket's close is the handler's defect, not the activation's:
        # one finding per server and handler, whichever sites make its
        # sockets active.
        key: {:source, %{"socket" => [:server, :handler], default: [:site, :server]}},
        doc: "A message a GenServer is sent that no clause of its handle_info/2 takes."
      },
      %{
        name: :monitor_leak_frame,
        fields: [
          {:mod, :symbol, "the module"},
          {:site, :symbol, "the monitor call site"},
          {:how, :symbol, "wait | ended | dropped"},
          {:role, :symbol,
           "drop (where the record is dropped) | runs (a root that runs the monitoring function again)"},
          {:func, :symbol, "the function the frame points at"}
        ],
        key: [:mod, :site, :how, :role, :func],
        evidence: %{of: :monitor_leak, on: [:mod, :site, :how], limit: 3},
        doc:
          "Where a server drops the record of a process it still monitors, and what runs the monitor again."
      },
      %{
        name: :task_yield_site,
        fields: [
          {:func, :symbol, "the function owning the task"},
          {:kind, :symbol, "yield_linked"},
          {:site, :symbol, "the Task.yield call"}
        ],
        key: [:func, :site],
        evidence: %{of: :task_result_defect, on: [:func, :kind], limit: 3},
        doc: "Where a linked task is collected with Task.yield, attached to its finding."
      },
      %{
        name: :task_result_defect,
        fields: [
          {:func, :symbol, "function starting the task"},
          {:site, :symbol, "instruction ID of the Task.async call"},
          {:kind, :symbol, "never_awaited | yield_linked | linked_in_library"}
        ],
        key: [:func, :site, :kind],
        doc: "A Task.async whose result nothing awaits, or whose link the caller cannot afford."
      },
      %{
        name: :monitor_leak,
        fields: [
          {:mod, :symbol, "the module"},
          {:func, :symbol, "the function that takes the monitor"},
          {:site, :symbol, "the monitor call site"},
          {:how, :symbol, "wait | ended | dropped"}
        ],
        key: [:mod, :func, :site, :how],
        doc:
          "A monitor that code which runs again takes again before the one before it is released."
      },
      %{
        name: :reply_defect,
        fields: [
          {:mod, :symbol, "the module"},
          {:func, :symbol, "the sender, the handle_call/3, or the state function"},
          {:site, :symbol, "the return site, empty for a self message"},
          {:kind, :symbol, "unhandled_call | unhandled_cast | dropped_from | statem_unreplied"},
          {:tag, :symbol, "the message tag, for a self message"}
        ],
        # A self message is one finding per tag, whoever sends it.
        key:
          {:kind,
           %{
             "unhandled_call" => [:mod, :tag],
             "unhandled_cast" => [:mod, :tag],
             default: [:mod, :func, :site]
           }},
        doc: "A tag the module cannot handle, or a reply a caller waits for that never comes."
      },
      Argus.Findings.Tooling.relation()
    ]
  end

  @impl true
  def finding(:timer_cancel_without_flush, [mod, func, _arm, "", message, cancel_site, arm_site]) do
    Findings.new(
      :warning,
      "Timer cancelled without flushing its message",
      "#{func} arms a timer with the message #{message} and cancels it before " <>
        "returning. If it fired first, Process.cancel_timer/1 leaves #{message} " <>
        "in the mailbox, and nothing flushes it, so the process handles a stale " <>
        "one after this call has finished, as if the timer had just fired: as the " <>
        "next call's timeout, or in handle_info/2.",
      at: Findings.at_site(cancel_site, mod),
      at_label: "cancels here",
      related: [Findings.related("armed with #{message} here", Findings.at_site(arm_site, mod))],
      help: [
        "flush after cancelling: `receive do #{message} -> :ok after 0 -> :ok end`",
        "or arm with :erlang.start_timer/3, whose `{:timeout, ref, msg}` names the timer, " <>
          "and match the ref"
      ]
    )
  end

  def finding(:timer_cancel_without_flush, [mod, cancel, arm, key, message, cancel_site, arm_site]) do
    Findings.new(
      :warning,
      "Timer cancelled without flushing its message",
      "#{mod} cancels the timer kept under #{key} in #{cancel} and arms it in " <>
        "#{arm} with the message #{message}, which carries nothing that " <>
        "identifies the timer. Process.cancel_timer/1 does not remove a message " <>
        "already delivered, and nothing flushes #{message} after the cancel, so " <>
        "a stale one is handled as if it were the next: the action runs twice, " <>
        "or early.",
      at: Findings.at_site(cancel_site, mod),
      at_label: "cancels here",
      related: [Findings.related("armed with #{message} here", Findings.at_site(arm_site, mod))],
      help: [
        "put the timer ref in the message (`{#{message}, ref}`) and match it against #{key}",
        "or flush after cancelling: `receive do #{message} -> :ok after 0 -> :ok end`"
      ]
    )
  end

  def finding(:timer_loop_rearmed, [mod, message, entry, site, _arm_site, loop_site, keeps]) do
    {why, loop_label} =
      case keeps do
        "" ->
          {"The loop's own re-arm drops the timer ref, so nothing can cancel the " <>
             "running timer:", "the loop re-arms here and keeps no ref"}

        key ->
          {"The loop keeps its timer ref under #{key}, and this path does not cancel " <>
             "it first:", "the loop re-arms here, keeping the ref under #{key}"}
      end

    Findings.new(
      :warning,
      "Periodic timer loop armed again while it runs",
      "#{mod}'s handle_info/2 re-arms #{message} each time it takes it, a loop, " <>
        "and #{Findings.call_name(entry)} arms #{message} again. #{why} " <>
        "every run of #{Findings.call_name(entry)} adds one more loop beside the " <>
        "ones already running, and the work each tick does multiplies with it.",
      at: Findings.at_site(site, mod),
      at_label: "arms #{message} again here",
      related: [Findings.related(loop_label, Findings.at_site(loop_site, mod))],
      help: [
        "keep the loop's ref in the state and cancel it before arming again",
        "or put a ref in the message (`{#{message}, ref}`) and let the loop drop a stale one",
        "or leave the arming to init/1 and the loop, and do the work directly here"
      ]
    )
  end

  def finding(:static_render_registration, [_mod, entry, func, site, kind]) do
    what =
      case kind do
        "subscribe" -> "subscribes it to a topic"
        "timer" -> "arms a timer to it"
        _ -> "monitors a process from it"
      end

    Findings.new(
      :warning,
      "LiveView registers for messages on the static render",
      "#{Findings.call_name(entry)} runs twice: first for the static render, in the " <>
        "HTTP connection's process, then in the LiveView's own once the socket " <>
        "connects. #{Findings.call_name(func)} #{what} on both runs, with no " <>
        "`connected?/1` test in the way: the first registers the HTTP connection's " <>
        "process, which a keep-alive client keeps alive, so it takes every " <>
        "message meant for the LiveView (the server logs each as unexpected) and " <>
        "the registration's work is done twice.",
      at: Findings.at_site_in_func(site, func),
      at_label: "runs on the static render too",
      related:
        if(func == entry,
          do: [],
          else: [Findings.related("the callback that reaches it", Findings.at_func(entry))]
        ),
      help: ["wrap it in `if connected?(socket) do ... end`"]
    )
  end

  def finding(:repeated_subscription, [mod, entry, func, site]) do
    Findings.new(
      :warning,
      "Subscription made again each time a callback runs",
      "#{Findings.call_name(entry)} runs again and again, and each run reaches " <>
        "#{Findings.call_name(func)}'s subscription. A second subscription to a " <>
        "topic the process already holds is not a no-op: every later broadcast " <>
        "arrives once more, and nothing #{mod} runs ever unsubscribes, so the " <>
        "copies accumulate for the life of the process.",
      at: Findings.at_site_in_func(site, func),
      at_label: "subscribes again on every run",
      related:
        if(func == entry,
          do: [],
          else: [Findings.related("the callback that runs it again", Findings.at_func(entry))]
        ),
      help: [
        "subscribe once, where the process starts (init/1, a mounted LiveView), or " <>
          "keep the topics subscribed in the state and skip the ones already there",
        "or unsubscribe from the previous topics before subscribing to the new ones"
      ]
    )
  end

  def finding(:unreceived_message, [mod, func, site, message, runs, starter, spawn, recv]) do
    Findings.new(
      :warning,
      "Message sent to a process whose receive never takes it",
      "#{Findings.call_name(func)} sends #{message} to the process spawned in " <>
        "#{Findings.call_name(starter)} to run #{Findings.call_name(runs)}, and no " <>
        "clause of a receive that process runs matches it. A " <>
        "message no receive takes is not dropped: it stays in the mailbox " <>
        "for the life of the process, every later receive scans past it, " <>
        "and the sender never learns it went nowhere.",
      at: Findings.at_site(site, mod),
      at_label: "#{message} is sent here",
      related: [
        # The receive's loop_rec carries no line: the bytecode puts the
        # frame on the function head, and the source finds the receive.
        Findings.related("a receive it never matches", Findings.at_instr(recv),
          at_source: "receive",
          to_block: :receive
        ),
        Findings.related("the process is spawned here", Findings.at_site_in_func(spawn, starter))
      ],
      help: [
        "add a clause for #{message} to the receive that should take it",
        "or send a message the process's receives expect"
      ]
    )
  end

  # The close of a socket the server holds: the handler is where the
  # clause is missing, and the activation is why the message comes.
  def finding(:unhandled_info, [mod, func, site, message, "socket", server, handler, fallback]) do
    {title, what} =
      case fallback do
        "crash" ->
          {"No handle_info/2 clause for the close of the server's socket",
           "none of its clauses matches it and there is no catch-all, so the first " <>
             "disconnect is a FunctionClauseError that takes the server down"}

        "catch_all" ->
          {"The close of the server's socket reaches only its catch-all handle_info/2",
           "no clause names it and the catch-all only logs or ignores it, so the server " <>
             "goes on holding a socket that is gone, and learns of it only when a send or " <>
             "a recv fails"}

        "default" ->
          {"The close of the server's socket reaches only GenServer's default handle_info/2",
           "the module wrote none of its handle_info/2: the one a macro wrote for it " <>
             "(GenServer's default, which logs it as an error) drops it, so the server " <>
             "goes on holding a socket that is gone"}

        "state_crash" ->
          {"No clause for the close of a gen_statem's socket",
           "no callback of the machine has a clause for it, and " <>
             "#{Findings.call_name(handler)} has no :info catch-all, so the first " <>
             "disconnect in that state is a FunctionClauseError that takes the machine down"}
      end

    Findings.new(
      :warning,
      title,
      "#{Findings.call_name(func)} makes #{socket_kind(message)} socket active in " <>
        "#{server}'s process, so the socket's end arrives there as #{message} whenever " <>
        "the connection goes, the peer closing or the network dropping: #{what}.",
      at: Findings.at_func(handler),
      at_label: "no clause here takes #{message}",
      related: [Findings.related("the socket is made active here", Findings.at_site(site, mod))],
      help: [
        "add a `handle_info(#{socket_clause(message)}, state)` clause that closes the " <>
          "connection and reconnects or stops",
        "or keep the socket passive (`active: false`) and read it with a timed recv, which " <>
          "returns `{:error, :closed}`"
      ]
    )
  end

  # What a timed receive leaves behind: anchored at the wait that gives
  # up, where the message was asked for and is not waited for long enough.
  def finding(:unhandled_info, [_mod, func, site, message, "late", server, handler, fallback]) do
    what =
      case fallback do
        "state_crash" ->
          "no callback of the machine has a clause for it, and " <>
            "#{Findings.call_name(handler)} has no :info catch-all, so in that state it is a " <>
            "FunctionClauseError that takes the machine down"

        _crash ->
          "none of its clauses matches it and there is no catch-all, so it is a " <>
            "FunctionClauseError that takes the server down"
      end

    Findings.new(
      :warning,
      "No handle_info/2 clause for a message a timed receive leaves behind",
      "#{Findings.call_name(func)} asks for #{late_message(message)} — it spawns the process " <>
        "that replies, or subscribes to what it waits for — and waits for it with an " <>
        "`after`. The wait can give up before the message comes: a reply sent as the " <>
        "timeout fires, or an event broadcast before the unsubscribe or about another " <>
        "subject than the one the receive selects, stays in the mailbox and reaches " <>
        "#{server}'s handle_info/2: #{what}.",
      # The loop_rec carries no line of its own: the source finds the receive.
      at: Findings.at_instr(site),
      at_source: "receive",
      to_block: :receive,
      at_label: "this wait can give up before the message comes",
      related: [
        Findings.related("the callback it reaches", Findings.at_func(handler),
          to_block: :function
        )
      ],
      help: [
        "add a handle_info/2 clause that takes #{late_clause(message)} and drops it",
        "or have the reply sent to an alias the wait deactivates when it gives up " <>
          "(`:erlang.alias/1`, as a GenServer.call does), or unsubscribe and flush before " <>
          "returning"
      ]
    )
  end

  def finding(:unhandled_info, [mod, func, site, message, source, server, handler, fallback]) do
    {title, severity, what} =
      case fallback do
        "crash" ->
          {"No handle_info/2 clause for a message the server is sent", crash_severity(source),
           "none of its clauses matches it and there is no catch-all, so it is a " <>
             "FunctionClauseError that takes the server down each time it arrives"}

        "catch_all" ->
          {"A message the server is sent reaches only its catch-all handle_info/2",
           catch_all_severity(source),
           "no clause names it, and the catch-all that takes it does nothing with it " <>
             "but log it or ignore it"}

        "default" ->
          {"A message is sent to a server with no handle_info/2 of its own", :warning,
           "the module wrote none of its handle_info/2: the one a macro wrote for it " <>
             "(GenServer's default, which logs the message as an error) drops it"}

        "state_crash" ->
          {"No clause for a message a gen_statem is sent", crash_severity(source),
           "it arrives as an :info event, no callback of the machine has a clause for " <>
             "it, and #{Findings.call_name(handler)} has no :info catch-all, so in that " <>
             "state it is a FunctionClauseError that takes the machine down"}
      end

    lands =
      if fallback == "state_crash",
        do: "whose callbacks take its events",
        else: "whose handle_info/2 is where it lands"

    Findings.new(
      severity,
      title,
      "#{sent(source, func, message)} #{server}, #{lands}: #{what}.",
      at: Findings.at_site(site, mod),
      at_label: sent_label(source),
      related: [
        Findings.related("the callback it reaches", Findings.at_func(handler),
          to_block: :function
        )
      ],
      help: unhandled_help(source, fallback, message)
    )
  end

  def finding(:task_result_defect, [func, id, "never_awaited"]) do
    Findings.new(
      :warning,
      "Async task never awaited",
      "#{func} starts a task with Task.async (or async_nolink) but nothing " <>
        "awaits or yields it. Task.async links to the caller and always sends " <>
        "a result message: a crashing task takes the caller down, and " <>
        "completed results accumulate unread in the mailbox.",
      at: Findings.at_instr(id),
      at_label: "task started here",
      help: [
        "consume the result with `Task.await/2` (or `Task.yield/2` plus " <>
          "`Task.shutdown/1`), or use `Task.Supervisor.start_child/2` for " <>
          "fire-and-forget work"
      ]
    )
  end

  def finding(:task_result_defect, [func, id, "yield_linked"]) do
    Findings.new(
      :warning,
      "Task.yield on a linked task cannot see it crash",
      "#{func} starts a task with Task.async (or Task.Supervisor.async), which " <>
        "links it to the caller, and collects it with Task.yield. yield's " <>
        "{:exit, reason} result is documented for a crashed task, but the link " <>
        "delivers the crash to this process first: unless it traps exits, the " <>
        "branch handling a failed task never runs — the caller is already down.",
      at: Findings.at_instr(id),
      at_label: "linked task started here",
      help: [
        "use `Task.Supervisor.async_nolink/2` so a crash reaches `Task.yield` as {:exit, reason}",
        "or trap exits in this process and handle the {:EXIT, ...} messages"
      ]
    )
  end

  def finding(:task_result_defect, [func, id, "linked_in_library"]) do
    Findings.new(
      :info,
      "Task.async in library code links to an unknown caller",
      "#{func} is a plain function, not a process callback, so the task it starts " <>
        "with Task.async is linked to whichever process called it. A caller that " <>
        "traps exits then receives the task's exit as an {:EXIT, pid, :normal} " <>
        "message that Task.await never consumes, and a crashing task takes the " <>
        "caller down with it.",
      at: Findings.at_instr(id),
      at_label: "linked task started in library code",
      help: [
        "use `Task.async_stream/3` or `Task.Supervisor.async_nolink/2`, " <>
          "or document that callers must not trap exits"
      ]
    )
  end

  def finding(:monitor_leak, [_mod, func, site, "wait"]) do
    Findings.new(
      :warning,
      "Monitor left live each time a wait returns",
      "#{Findings.call_name(func)} runs again and again, and each run monitors a " <>
        "process and waits for its :DOWN. Some way out of the wait returns with the " <>
        "monitor still live: the `after` clause gave up, or the answer came first, " <>
        "and nothing demonitors the ref. The next run monitors the same process " <>
        "again, so the monitors pile up on it, one per run, until it exits; then " <>
        "every one of them sends a :DOWN into whatever the process runs by then.",
      at: Findings.at_site_in_func(site, func),
      at_label: "left live on some way out of the wait",
      help: [
        "demonitor the ref on every way out: `Process.demonitor(ref, [:flush])` " <>
          "after the answer and on the timeout"
      ]
    )
  end

  def finding(:monitor_leak, [mod, func, site, "ended"]) do
    Findings.new(
      :warning,
      "Entry dropped while its process stays monitored",
      "#{Findings.call_name(func)} runs again and again: each run monitors a process " <>
        "and records it in #{mod}. Another of #{mod}'s callbacks drops that record " <>
        "while the process may still be alive (a delete, an unsubscribe, a reset) " <>
        "and does not demonitor it. The monitor outlives the entry it stood for: " <>
        "when the same process registers again it is monitored again, and the old " <>
        "monitors pile up until it exits.",
      at: Findings.at_site_in_func(site, func),
      at_label: "monitored here; the entry is dropped elsewhere",
      help: [
        "keep the ref with the entry, and `Process.demonitor(ref, [:flush])` where " <>
          "the entry is dropped"
      ]
    )
  end

  def finding(:monitor_leak, [_mod, func, site, "dropped"]) do
    Findings.new(
      :info,
      "Monitor taken again with its ref thrown away",
      "#{Findings.call_name(func)} runs again and again, monitors a process and " <>
        "throws the ref away, without asking its state whether it already monitors " <>
        "that process. Only the process's exit can end the monitor: each time the " <>
        "same process is named again, one more piles up, and each is a :DOWN that " <>
        "comes later, for a relationship that may have ended. Whether the same " <>
        "process is named again is the protocol's, which the code does not show.",
      at: Findings.at_site_in_func(site, func),
      at_label: "the ref is thrown away here",
      help: [
        "keep the ref with what the monitor stands for, and demonitor it when that " <>
          "ends; or monitor a process only when the state holds no monitor of it"
      ]
    )
  end

  def finding(:reply_defect, [mod, sender, _, "unhandled_" <> kind, tag]) do
    Findings.new(
      :error,
      "Server sends itself a tag it cannot handle",
      "#{sender} sends #{tag} via GenServer.#{kind}/2, and #{mod}'s " <>
        "handle_#{kind} has no clause matching it and no catch-all. " <>
        consequence(kind) <>
        " The two halves of this contract live in different places and " <>
        "nothing checks they agree, so renaming a tag on one side compiles " <>
        "clean and fails only when that path runs.",
      at: Findings.at_func(sender),
      at_label: "sends #{tag} to itself from here",
      help: ["add a handle_#{kind} clause for #{tag}, or fix the tag at this call"]
    )
  end

  def finding(:reply_defect, [_mod, func, id, "dropped_from", _]) do
    Findings.new(
      :error,
      "handle_call/3 defers a reply it cannot send",
      "#{func} returns {:noreply, _}, which promises a later GenServer.reply/2, " <>
        "but never reads its `from` argument. `from` is the only handle on the " <>
        "caller — an opaque {pid, tag} that exists nowhere else — so nothing in " <>
        "the system can discharge that promise. " <>
        "Every caller reaching this clause blocks for its full GenServer.call/3 " <>
        "timeout and then exits. The exit is raised in the caller, in another " <>
        "module, with a message that names neither this function nor this clause, " <>
        "and under load it is indistinguishable from overload.",
      at: Findings.at_instr(id),
      to_block: :clause,
      at_label: "{:noreply, _} without keeping `from`",
      help: [
        "reply here with `{:reply, value, state}`, or keep `from` in state and " <>
          "`GenServer.reply/2` when the work completes"
      ]
    )
  end

  def finding(:unhandled_timeout, [mod, state, kind]) do
    {action, type} =
      case kind do
        "state_timeout" -> {"{:state_timeout, ms, content}", ":state_timeout"}
        "generic_timeout" -> {"{{:timeout, name}, ms, content}", "{:timeout, name}"}
        _ -> {"{:timeout, ms, content}", ":timeout"}
      end

    at =
      case state do
        "handle_event" -> Findings.at_mfa(mod, :handle_event, 4)
        name -> Findings.at_mfa(mod, String.to_atom(name), 3)
      end

    Findings.new(
      :error,
      "Timeout armed but never handled",
      "#{mod} arms a #{action} action in #{state}, which delivers an event " <>
        "of type #{type} — and no clause matches that event type. When the " <>
        "timer fires the event either raises FunctionClauseError or falls " <>
        "through to a clause written for something else; the work the " <>
        "timeout was meant to trigger never runs. A common shape is " <>
        "handling it as `(:info, :timeout, ...)`: the event type is " <>
        "#{type}, not :info.",
      at: at,
      at_label: "the timeout is armed here",
      help: ["add a clause matching `(#{type}, content, ...)` for the armed timeout"]
    )
  end

  def finding(:reply_defect, [mod, func, site, "statem_unreplied", tag]) do
    Findings.new(
      :error,
      "A {:call, from} clause never replies",
      "#{func} handles a {:call, from} event in this clause and returns " <>
        "without a {:reply, from, _} action, without postponing the event, and " <>
        "without keeping `from` for a later reply. The caller of " <>
        ":gen_statem.call/2 waits :infinity by default, so it stays blocked for " <>
        "as long as #{mod} lives.",
      # The bytecode lands on the clause's pattern test, which carries the
      # previous clause's line; the tested literal finds the clause head.
      at: Findings.at_site(site, mod),
      at_source: if(tag == "", do: nil, else: tag),
      to_block: :clause,
      at_label: "this clause never replies",
      help: [
        "return `{:keep_state_and_data, [{:reply, from, value}]}` (or `:postpone` " <>
          "the event until a state that can answer)",
        "if the caller must not wait, give the call a timeout"
      ]
    )
  end

  defp consequence("call") do
    "The server raises FunctionClauseError and exits; the caller's " <>
      "GenServer.call exits with it, pointing at the call rather than at the " <>
      "missing clause."
  end

  defp consequence("cast") do
    "Casts are fire-and-forget, so the caller is told nothing: the server " <>
      "dies, the supervisor restarts it, its state is gone, and the only " <>
      "trace is a crash report nobody connected to this function."
  end

  defp consequence(_other), do: ""

  @impl true
  def evidence(:monitor_leak_frame, [_mod, _site, _how, "drop", func]) do
    Findings.related("the entry is dropped here, the monitor stays", Findings.at_func(func))
  end

  def evidence(:monitor_leak_frame, [_mod, _site, _how, "runs", root]) do
    Findings.related("runs again from here", Findings.at_func(root))
  end

  def evidence(:task_yield_site, [func, _kind, site]) do
    Findings.related("collected with Task.yield here", Findings.at_site_in_func(site, func))
  end

  def evidence(:timer_cancel_under_test, [mod, _key, site, _func]) do
    Findings.related(
      "also cancelled here, on a path only the tests take",
      Findings.at_site(site, mod)
    )
  end

  # A monitor's :DOWN dropped by a catch-all is a monitor that does
  # nothing: the cleanup it was taken for is missing. A message the
  # program sends may be meant for the catch-all.
  defp catch_all_severity("monitor"), do: :warning
  defp catch_all_severity(_source), do: :info

  # A message the program sends or arms itself crashes the server on the
  # path that sends it, with nothing else needed: the rubric's :error, as
  # a call or cast with a tag the server cannot take is. What the runtime
  # writes when something else happens — a monitored process ends, a node
  # joins or leaves, a port's program writes — is :warning.
  defp crash_severity(source) when source in ["monitor", "node", "port", "task", "exit"],
    do: :warning

  defp crash_severity(_sent_or_armed), do: :error

  defp late_message("{ref, …}"), do: "a reply that carries a ref it holds, {ref, …},"
  defp late_message("map"), do: "a map"
  defp late_message("tuple"), do: "a tuple"
  defp late_message(message), do: message

  defp late_clause("{ref, …}"), do: "a late `{ref, _}`"
  defp late_clause("map"), do: "the map"
  defp late_clause("tuple"), do: "the tuple"
  defp late_clause(message), do: "a late #{message}"

  defp socket_kind("{:ssl_closed, …}"), do: "a TLS"
  defp socket_kind(_tcp), do: "a TCP"

  defp socket_clause("{:ssl_closed, …}"), do: "{:ssl_closed, socket}"
  defp socket_clause(_tcp), do: "{:tcp_closed, socket}"

  defp sent("monitor", func, _message),
    do:
      "#{Findings.call_name(func)} takes a monitor from a server's callbacks, so its " <>
        "{:DOWN, …}, with whatever reason the monitored process or port ends with, goes to"

  defp sent("timer", func, message),
    do: "#{Findings.call_name(func)} arms a timer that sends #{message} to"

  defp sent("task", func, "{ref, …}"),
    do:
      "#{Findings.call_name(func)} starts a task with Task.Supervisor.async_nolink from a " <>
        "server's callbacks and does not collect it there, so the task's reply, " <>
        "{ref, result}, goes to"

  defp sent("task", func, _down),
    do:
      "#{Findings.call_name(func)} starts a task with Task.Supervisor.async_nolink from a " <>
        "server's callbacks and does not collect it there, so the task's {:DOWN, …}, sent " <>
        "when it ends (after its reply, or in its place when it crashes), goes to"

  defp sent("exit", func, _message),
    do:
      "#{Findings.call_name(func)} links a server that traps exits to a process or a " <>
        "port (a spawn_link, a start_link, a link, a port it opens), so its end arrives " <>
        "as {:EXIT, …}, with whatever reason it ends with, at"

  defp sent("node", func, message),
    do:
      "#{Findings.call_name(func)} turns on node monitoring from a server's callbacks, so " <>
        "the runtime sends #{message} whenever a node joins or leaves, to"

  defp sent("port", func, message),
    do:
      "#{Findings.call_name(func)} opens a port from a server's callbacks, so what the " <>
        "port's program writes arrives as #{message} at"

  defp sent(_send, func, message), do: "#{Findings.call_name(func)} sends #{message} to"

  defp sent_label("monitor"), do: "the :DOWN of this monitor"
  defp sent_label("timer"), do: "the timer is armed here"
  defp sent_label("task"), do: "the task is started here"
  defp sent_label("exit"), do: "the link is made here"
  defp sent_label("node"), do: "node monitoring is turned on here"
  defp sent_label("port"), do: "the port is opened here"
  defp sent_label(_send), do: "the message is sent here"

  defp unhandled_help("monitor", _fallback, _message),
    do: [
      "add a `handle_info({:DOWN, ref, type, object, reason}, state)` clause that takes " <>
        "every reason and releases what the monitor was for",
      "or wait for the :DOWN where the monitor is taken, or demonitor it with `[:flush]`"
    ]

  defp unhandled_help("exit", _fallback, _message),
    do: [
      "add a `handle_info({:EXIT, pid, reason}, state)` clause that takes every reason: " <>
        "a linked process that crashes sends its crash's",
      "or start the process under a supervisor, or monitor it rather than link"
    ]

  defp unhandled_help("task", _fallback, _message),
    do: [
      "add `handle_info({ref, result}, state) when is_reference(ref)` and " <>
        "`handle_info({:DOWN, ref, :process, _pid, reason}, state)` clauses",
      "or collect the task where it is started with Task.yield/2 and Task.shutdown/1"
    ]

  defp unhandled_help("node", _fallback, message),
    do: [
      "add a handle_info/2 clause for #{message}",
      "or turn node monitoring on in a process that takes the events"
    ]

  defp unhandled_help("port", _fallback, _message),
    do: [
      "add a `handle_info({port, {:data, data}}, state)` clause for the port's output",
      "or read the port where it is opened, in a receive, until it closes"
    ]

  defp unhandled_help(_source, "catch_all", message),
    do: [
      "add a handle_info/2 clause for #{message}",
      "or, if the catch-all is meant to take it, stop sending it"
    ]

  defp unhandled_help(_source, _fallback, message),
    do: ["add a handle_info/2 clause for #{message}", "or send a message a clause takes"]
end
