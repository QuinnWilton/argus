defmodule Argus.Analyses.Mailbox do
  @moduledoc """
  A message arrives and nothing takes it, or takes it wrongly.

  A process's mailbox is written by more than its owner. Every finding
  here is a message and the clause that is not there for it, or a reply
  a caller waits for that never comes.

  - `handle_info_without_catchall(mod, func)` and
    `handle_info_partial(mod, func)` — a `handle_info/2` with no
    catch-all, in a process the runtime writes to (monitors, trapped
    exits) or one whose callbacks reach a late-message source (a task, a
    timer, a subscription, a timed call).
  - `nolink_messages_unhandled(mod, start, handler, missing)` — an
    `async_nolink` task's reply or `:DOWN` has no clause.
  - `leaked_async_task`, `yield_on_linked_task`, `linked_task_in_library`
    — a `Task.async` never awaited, collected with `Task.yield` in a
    process that does not trap exits, or started in library code that
    links it to an unknown caller.
  - `leaked_monitor`, `monitor_never_released`, `monitor_ref_discarded` —
    a monitor left live after a timed wait, released by nothing but the
    monitored process dying, or whose ref was thrown away.
  - `timer_cancel_without_flush(mod, cancel, arm, key, message)` — a
    cancelled timer's message may already be queued and is not told
    apart from the next.
  - `unhandled_self_message(mod, sender, kind, tag)` — a tag the module
    sends its own server with no matching clause.
  - `never_replies(mod, func, id)` — a `handle_call` that defers a reply
    without keeping `from`.
  - `state_missing_info_catchall`, `statem_timeout_unhandled`,
    `call_never_replied` — a gen_statem state without the `:info`
    catch-all its siblings have, a timeout no clause handles, a
    `{:call, from}` clause that never answers.
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

  @reply_fields [
    {:mod, :symbol, "the module"},
    {:func, :symbol, "the handle_call/3 function"},
    {:id, :symbol, "the return site"}
  ]

  @impl true
  def output_relations do
    [
      %{
        name: :handle_info_without_catchall,
        fields: [
          {:mod, :symbol, "module"},
          {:func, :symbol, "the handle_info/2 function"}
        ],
        doc:
          "A GenServer that monitors or traps exits defines handle_info/2 " <>
            "without a catch-all clause."
      },
      %{
        name: :handle_info_partial,
        fields: [
          {:mod, :symbol, "module"},
          {:func, :symbol, "the handle_info/2 function"}
        ],
        doc:
          "A GenServer or GenStage defines handle_info/2 without a catch-all " <>
            "clause; nothing in the module invites runtime messages, but any " <>
            "stray message is a FunctionClauseError."
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
        name: :nolink_messages_unhandled,
        fields: [
          {:mod, :symbol, "the process module"},
          {:start, :symbol, "function starting the async_nolink task"},
          {:handler, :symbol, "its handle_info/2"},
          {:missing, :symbol, "'reply' ({ref, result}) or 'down' ({:DOWN, ...})"}
        ],
        key: [:mod, :start],
        doc: "An async_nolink task's reply or :DOWN message has no handle_info clause."
      },
      %{
        name: :leaked_async_task,
        fields: [
          {:func, :symbol, "function containing the async call"},
          {:id, :symbol, "instruction ID of the Task.async call"}
        ],
        doc: "Task.async or async_nolink call without corresponding await/yield."
      },
      %{
        name: :yield_on_linked_task,
        fields: [
          {:func, :symbol, "function that starts and yields on the task"},
          {:id, :symbol, "instruction ID of the Task.async call"}
        ],
        doc: "A linked task is collected with Task.yield in a caller that does not trap exits."
      },
      %{
        name: :linked_task_in_library,
        fields: [
          {:func, :symbol, "library function that starts the task"},
          {:id, :symbol, "instruction ID of the Task.async call"}
        ],
        doc:
          "Task.async in a function that is not a process callback links the task to an unknown caller."
      },
      %{
        name: :leaked_monitor,
        fields: [
          {:func, :symbol, "the function establishing the monitor"},
          {:id, :symbol, "the monitor call site"}
        ],
        key: [:func],
        doc: "A monitor established before a timed wait, never flushed."
      },
      %{
        name: :monitor_never_released,
        fields: [
          {:mod, :symbol, "the server module"},
          {:site, :symbol, "a monitor call site in its callbacks"}
        ],
        key: [:mod],
        doc:
          "A server monitors from its callbacks and removes bookkeeping entries, " <>
            "but never calls Process.demonitor."
      },
      %{
        name: :monitor_ref_discarded,
        fields: [
          {:mod, :symbol, "the server module"},
          {:site, :symbol, "the monitor call whose ref is dropped"}
        ],
        doc:
          "A server callback discards the ref Process.monitor/1 returned; nothing can demonitor it."
      },
      %{
        name: :unhandled_self_message,
        fields: [
          {:mod, :symbol, "the module"},
          {:sender, :symbol, "the function sending it"},
          {:kind, :symbol, "'call' or 'cast'"},
          {:tag, :symbol, "the message tag"}
        ],
        key: [:mod, :kind, :tag],
        doc: "A tag sent to the module's own server with no matching clause."
      },
      %{
        name: :never_replies,
        fields: @reply_fields,
        key: [:mod, :func, :id],
        doc: "handle_call returns {:noreply, _} without keeping `from`."
      },
      %{
        name: :state_missing_info_catchall,
        fields: [
          {:mod, :symbol, "module"},
          {:state, :symbol, "the state without an :info catch-all"},
          {:site, :symbol, "the state function"}
        ],
        doc: "A state function has no :info catch-all while sibling states do."
      },
      %{
        name: :statem_timeout_unhandled,
        fields: [
          {:mod, :symbol, "module"},
          {:kind, :symbol, "event_timeout, state_timeout or generic_timeout"},
          {:state, :symbol, "the state (or handle_event) arming it"}
        ],
        key: [:mod, :kind],
        doc: "A timeout is armed and no clause handles its event type."
      },
      %{
        name: :call_never_replied,
        fields: [
          {:mod, :symbol, "module"},
          {:func, :symbol, "the state function or handle_event/4"},
          {:site, :symbol, "the return that answers nothing"}
        ],
        doc: "A {:call, from} clause returns without replying, postponing, or keeping from."
      }
    ]
  end

  @impl true
  def finding(:handle_info_without_catchall, [mod, func]) do
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

  def finding(:handle_info_partial, [mod, func]) do
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

  def finding(:nolink_messages_unhandled, [mod, start, handler, missing]) do
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

  def finding(:leaked_async_task, [func, id]) do
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

  def finding(:yield_on_linked_task, [func, id]) do
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

  def finding(:linked_task_in_library, [func, id]) do
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

  def finding(:leaked_monitor, [func, id]) do
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

  def finding(:monitor_never_released, [mod, site]) do
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

  def finding(:monitor_ref_discarded, [mod, site]) do
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

  def finding(:unhandled_self_message, [mod, sender, kind, tag]) do
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

  def finding(:never_replies, [mod, func, id]) do
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

  def finding(:state_missing_info_catchall, [mod, state, site]) do
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

  def finding(:statem_timeout_unhandled, [mod, kind, state]) do
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

  def finding(:call_never_replied, [mod, func, site]) do
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
