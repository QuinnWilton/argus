defmodule Argus.Analyses.Mailbox do
  @moduledoc """
  A message arrives and nothing takes it, or takes it wrongly.

  A process's mailbox is written by more than its owner. Every finding
  here is a message and the clause that is not there for it, or a reply
  a caller waits for that never comes.

  - `partial_handler(mod, handler, source, missing, detail)` — a message
    with no clause for it. `source` says who writes it: `runtime`
    (monitors, trapped exits), `late_message` (a task, a timer, a
    subscription, a timed call the callbacks reach), `task_nolink` (an
    `async_nolink` task's `reply` or `down`), `statem_timeout` (a timeout
    of kind `missing` no clause handles), `statem_info` (a state without
    the `:info` catch-all its siblings have).
  - `task_result_defect(func, site, kind)` — a `Task.async`
    `never_awaited`, `yield_linked` (collected with `Task.yield` in a
    process that does not trap exits) or `linked_in_library` (started in
    library code that links it to an unknown caller).
  - `unconsumed_monitor(mod, func, site, kind)` — a monitor left live
    after a `timed_wait`, `never_released` by anything but the monitored
    process dying, or whose ref was `ref_discarded`.
  - `timer_cancel_without_flush(mod, cancel, arm, key, message)` — a
    cancelled timer's message may already be queued and is not told
    apart from the next.
  - `reply_defect(mod, func, site, kind, tag)` — a tag the module sends
    its own server with no matching clause (`self_call`, `self_cast`), a
    `handle_call` that defers a reply without keeping `from`
    (`dropped_from`), or a `{:call, from}` clause that never answers
    (`statem_unreplied`).
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
      Argus.Extractors.Reply
    ]

  @impl true
  def output_relations do
    [
      %{
        name: :partial_handler,
        fields: [
          {:mod, :symbol, "the process module"},
          {:handler, :symbol,
           "the handle_info/2 function, or the statem state (name or handle_event)"},
          {:source, :symbol,
           "runtime | late_message | task_nolink | statem_timeout | statem_info"},
          {:missing, :symbol,
           "catchall, reply | down for task_nolink, the timeout kind for statem_timeout"},
          {:detail, :symbol, "the function starting the task, or the state name for statem_info"}
        ],
        # A nolink task is one finding per start; a statem timeout one per
        # kind; the rest one per handler.
        key:
          {:source,
           %{
             "task_nolink" => [:mod, :detail],
             "statem_timeout" => [:mod, :missing],
             default: [:mod, :handler, :missing, :detail]
           }},
        doc: "A message arrives and no clause takes it."
      },
      %{
        name: :timer_cancel_without_flush,
        fields: [
          {:mod, :symbol, "the process module"},
          {:cancel, :symbol, "function cancelling the timer"},
          {:arm, :symbol, "function arming a timer whose message carries no ref"},
          {:key, :symbol, "the state key holding the timer ref"},
          {:message, :symbol, "the timer's message"}
        ],
        key: [:mod, :key],
        doc: "A cancelled timer's message may already be in the mailbox and is not told apart."
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
        name: :unconsumed_monitor,
        fields: [
          {:mod, :symbol, "the module"},
          {:func, :symbol, "the function establishing the monitor"},
          {:site, :symbol, "the monitor call site"},
          {:kind, :symbol, "timed_wait | never_released | ref_discarded"}
        ],
        # A timed wait leaks once per function, a server that never
        # demonitors is one finding, a discarded ref one per site.
        key:
          {:kind,
           %{"timed_wait" => [:func], "never_released" => [:mod], default: [:mod, :func, :site]}},
        doc: "A monitor left live past the wait, the entry, or the ref that could release it."
      },
      %{
        name: :reply_defect,
        fields: [
          {:mod, :symbol, "the module"},
          {:func, :symbol, "the sender, the handle_call/3, or the state function"},
          {:site, :symbol, "the return site, empty for a self message"},
          {:kind, :symbol, "self_call | self_cast | dropped_from | statem_unreplied"},
          {:tag, :symbol, "the message tag, for a self message"}
        ],
        # A self message is one finding per tag, whoever sends it.
        key:
          {:kind,
           %{
             "self_call" => [:mod, :tag],
             "self_cast" => [:mod, :tag],
             default: [:mod, :func, :site]
           }},
        doc: "A tag the module cannot handle, or a reply a caller waits for that never comes."
      }
    ]
  end

  @impl true
  def finding(:partial_handler, [mod, func, "runtime", _, _]) do
    Findings.new(
      :info,
      "handle_info/2 has no catch-all in a process the runtime writes to",
      "#{mod} monitors processes or traps exits, so messages arrive at " <>
        "times it does not control — a late {:DOWN, ...} after a " <>
        "demonitor without :flush, an {:EXIT, ...} from a port a callback " <>
        "opened. Its handle_info/2 matches specific messages only, and " <>
        "once handle_info/2 is defined an unmatched message is a " <>
        "FunctionClauseError rather than GenServer's log-and-continue.",
      at: Findings.at_func(func),
      at_label: "no clause here accepts an unexpected message",
      help: [
        "add a final `handle_info(msg, state)` clause that logs the " <>
          "message and returns `{:noreply, state}`"
      ]
    )
  end

  def finding(:partial_handler, [mod, func, "late_message", _, _]) do
    Findings.new(
      :info,
      "handle_info/2 has no catch-all",
      "#{mod} matches specific messages in handle_info/2 and nothing else. " <>
        "A mailbox is written by more than its owner: a library it called " <>
        "can leave a late reply, a supervisor restart can re-send a " <>
        "start-up message. Once handle_info/2 is defined, one such message " <>
        "is a FunctionClauseError and the process dies — in a restart loop " <>
        "if the message repeats.",
      at: Findings.at_func(func),
      at_label: "no clause here accepts an unexpected message",
      help: [
        "add a final `handle_info(msg, state)` clause that logs the " <>
          "message and returns `{:noreply, state}`"
      ]
    )
  end

  def finding(:timer_cancel_without_flush, [mod, cancel, arm, key, message]) do
    Findings.new(
      :warning,
      "Timer cancelled without flushing its message",
      "#{mod} cancels the timer kept under #{key} in #{cancel} and arms it in " <>
        "#{arm} with the message #{message}, which carries nothing that " <>
        "identifies the timer. Process.cancel_timer/1 does not remove a message " <>
        "already delivered, and no receive in the module takes #{message}, so " <>
        "a stale one is handled as if it were the next: the action runs twice, " <>
        "or early.",
      at: Findings.at_func(cancel),
      at_label: "cancels here",
      help: [
        "put the timer ref in the message (`{#{message}, ref}`) and match it against #{key}",
        "or flush after cancelling: `receive do #{message} -> :ok after 0 -> :ok end`"
      ]
    )
  end

  def finding(:partial_handler, [mod, handler, "task_nolink", missing, start]) do
    what =
      case missing do
        "reply" -> "the task's reply, `{ref, result}`"
        _ -> "the task's exit, `{:DOWN, ref, :process, pid, reason}`"
      end

    Findings.new(
      :warning,
      "async_nolink task's messages have no handle_info clause",
      "#{start} starts a task with Task.Supervisor.async_nolink from #{mod}'s " <>
        "callbacks and does not collect it there, so #{what} lands in " <>
        "#{handler} — which matches other messages and has no clause for it. " <>
        "The first task to finish is a FunctionClauseError.",
      at: Findings.at_func(start),
      at_label: "async_nolink started here",
      help: [
        "add `handle_info({ref, result}, state) when is_reference(ref)` and " <>
          "`handle_info({:DOWN, ref, :process, _pid, reason}, state)` clauses",
        "or collect the task where it is started with Task.yield/2 and Task.shutdown/1"
      ]
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

  def finding(:unconsumed_monitor, [_mod, func, id, "timed_wait"]) do
    Findings.new(
      :error,
      "#{func} leaves a monitor live after its wait times out",
      "#{func} calls Process.monitor/1 and then waits in a receive with an " <>
        "after clause, without Process.demonitor(ref, [:flush]). " <>
        "On the timeout branch the monitor is still live, so the " <>
        "{:DOWN, ref, :process, object, reason} arrives later — after the " <>
        "function returned, into whatever callback is running then. " <>
        "Two things usually follow. If no clause matches that message the " <>
        "process dies with a bad-event or FunctionClauseError, and it dies on " <>
        "an error path, which is when its state is most worth keeping. If a " <>
        "clause does match, it runs with a reason describing something the " <>
        "code stopped caring about. " <>
        "Note that plain Process.demonitor(ref) is not enough: a {:DOWN, ...} " <>
        "already in the mailbox stays there, and only the [:flush] option " <>
        "removes it. " <>
        "A receive with no after clause does not have this problem, since it " <>
        "consumes either the reply or the {:DOWN, ...}.",
      at: Findings.at_instr(id)
    )
  end

  def finding(:unconsumed_monitor, [mod, _func, site, "never_released"]) do
    Findings.new(
      :info,
      "#{mod} monitors but never demonitors",
      "#{mod} establishes monitors from its callbacks and removes entries " <>
        "from its bookkeeping elsewhere, but calls Process.demonitor nowhere. " <>
        "If an entry can leave by a path other than the monitored process " <>
        "dying — an explicit delete, unsubscribe or disconnect — its monitor " <>
        "stays live: one per cycle, for the life of the server, each one a " <>
        "future {:DOWN, ...} that arrives after the entry is gone.",
      at: Findings.at_site(site, mod),
      at_label: "monitors established here are only ever released by :DOWN",
      help: [
        "on every path that removes the entry, call " <>
          "`Process.demonitor(ref, [:flush])` with the ref stored alongside it"
      ]
    )
  end

  def finding(:unconsumed_monitor, [mod, _func, site, "ref_discarded"]) do
    Findings.new(
      :info,
      "#{mod} drops the ref of a monitor it establishes",
      "#{mod} calls Process.monitor/1 in a callback and discards the " <>
        "result. The ref is the only handle a demonitor needs, so this " <>
        "monitor ends when the monitored process dies and not before. If " <>
        "the relationship it stands for can end another way — an " <>
        "unsubscribe, a checkin, a disconnect — the monitor outlives it, " <>
        "one per cycle, and the {:DOWN, ...} arrives for a process the " <>
        "server stopped caring about.",
      at: Findings.at_site(site, mod),
      at_label: "the monitor ref is dropped here",
      help: [
        "keep the ref with the entry it protects and " <>
          "`Process.demonitor(ref, [:flush])` when the entry is removed"
      ]
    )
  end

  def finding(:reply_defect, [mod, sender, _, "self_" <> kind, tag]) do
    Findings.new(
      :error,
      "#{mod} sends itself #{tag}, which it cannot handle",
      "#{sender} sends #{tag} via GenServer.#{kind}/2, and #{mod}'s " <>
        "handle_#{kind} has no clause matching it and no catch-all. " <>
        consequence(kind) <>
        " The two halves of this contract live in different places and " <>
        "nothing checks they agree, so renaming a tag on one side compiles " <>
        "clean and fails only when that path runs. " <>
        "Either add the clause, or fix the tag at the call site.",
      at: Findings.at_func(sender)
    )
  end

  def finding(:reply_defect, [mod, func, id, "dropped_from", _]) do
    Findings.new(
      :error,
      "#{mod} defers a reply it cannot send",
      "#{func} returns {:noreply, _}, which promises a later GenServer.reply/2, " <>
        "but never reads its `from` argument. `from` is the only handle on the " <>
        "caller — an opaque {pid, tag} that exists nowhere else — so nothing in " <>
        "the system can discharge that promise. " <>
        "Every caller reaching this clause blocks for its full GenServer.call/3 " <>
        "timeout and then exits. The exit is raised in the caller, in another " <>
        "module, with a message that names neither this function nor this clause, " <>
        "and under load it is indistinguishable from overload. " <>
        "Either reply directly with {:reply, value, state}, or store `from` in " <>
        "state and reply when the work completes.",
      at: Findings.at_instr(id)
    )
  end

  def finding(:partial_handler, [mod, site, "statem_info", _, state]) do
    Findings.new(
      :warning,
      "State #{state} has no :info catch-all",
      "#{mod}'s other states end with an `(:info, _msg, _data)` clause; " <>
        "#{state} does not. Any message that arrives while the machine is " <>
        "in #{state} and matches none of its clauses — a late :DOWN, a " <>
        "reply to a call that timed out, a library's notification — is a " <>
        "FunctionClauseError, and takes the process (and under :one_for_all, " <>
        "its whole tree) down with it.",
      at: Findings.at_site(site, mod),
      at_label: "no clause here accepts an unexpected message",
      help: ["add a final `#{state}(:info, _msg, data)` clause, as the other states have"]
    )
  end

  def finding(:partial_handler, [mod, state, "statem_timeout", kind, _]) do
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

  def finding(:reply_defect, [mod, func, site, "statem_unreplied", _]) do
    Findings.new(
      :warning,
      "A {:call, from} clause never replies",
      "#{func} handles a {:call, from} event and, on the path ending here, returns " <>
        "without a {:reply, from, _} action, without postponing the event, and " <>
        "without keeping `from` for a later reply. The caller of " <>
        ":gen_statem.call/2 waits :infinity by default, so it stays blocked for " <>
        "as long as #{mod} lives.",
      at: Findings.at_site(site, mod),
      at_label: "returns here without answering the call",
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
end
