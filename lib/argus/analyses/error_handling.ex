defmodule Argus.Analyses.ErrorHandling do
  @moduledoc """
  Error handling analysis.

  Detects error handling anti-patterns: bare rescues that silently swallow
  exceptions, trap_exit without matching handler, exit calls in GenServer
  callbacks, and ignored start results.

  ## Output relations

  - `swallowed_error(func)` — catch-all rescue that silently discards
    exceptions (a handler that reifies the exception into a returned/
    logged value or re-raises it is not flagged).
  - `trap_exit_without_handler(mod)` — traps exits but no handle_info callback at all.
  - `trap_exit_without_exit_clause(mod, witness)` — traps exits and has a
    handle_info/2, but no clause matches `{:EXIT, ...}` and none is a
    catch-all.
  - `handle_info_without_catchall(mod, func)` — a GenServer that monitors
    or traps exits defines handle_info/2 without a catch-all clause, so a
    message the runtime sends at a time of its choosing crashes it.
  - `handle_info_partial(mod, func)` — a GenServer or GenStage defines
    handle_info/2 without a catch-all and nothing in the module invites
    runtime messages; any stray message is still a FunctionClauseError.
  - `exit_in_callback(func, target)` — an exit *signal* (Process.exit/2)
    sent from a GenServer callback.
  - `ignored_start_result(func, callee)` — GenServer/Supervisor start result not checked.

  ## Finding severities

  `swallowed_error`, `trap_exit_without_handler`,
  `trap_exit_without_exit_clause` and `ignored_start_result` are
  `:warning`: each silently discards failure information — errors, exit
  signals, or failed starts — so the bug surfaces later, far from its
  cause. `handle_info_without_catchall` and `handle_info_partial` are
  `:info`: whether a stray message is worth crashing over is a judgement
  call; the first names a process that has invited such messages. `exit_in_callback` is `:info`:
  imperatively killing a process is frequently a deliberate protocol
  (handoff, conflict resolution), so it is surfaced for confirmation
  rather than flagged as a defect.
  """

  @behaviour Argus.Analysis

  alias Argus.Findings

  @impl true
  def name, do: :error_handling

  @impl true
  def description,
    do: "Error handling anti-patterns: swallowed errors, ignored results, exit misuse"

  @impl true
  def rules_file, do: "analyses/error_handling.dl"

  @impl true
  def extractors,
    do: [
      Argus.Extractors.ErrorHandling,
      Argus.Extractors.OTP,
      Argus.Extractors.CallArgs,
      Argus.Extractors.ApiCalls,
      Argus.Extractors.CallbackTag,
      Argus.Extractors.Monitor
    ]

  @impl true
  def output_relations do
    [
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
        name: :partial_noproc_catch,
        fields: [
          {:func, :symbol, "function making the call"},
          {:site, :symbol, "the try"},
          {:callee, :symbol, "the guarded call"}
        ],
        key: [:func, :site],
        doc: "A peer call whose catch covers :noproc but not the peer stopping mid-call."
      },
      %{
        name: :swallowed_error,
        fields: [{:func, :symbol, "function with bare rescue"}],
        doc: "Catch-all rescue that silently discards exceptions."
      },
      %{
        name: :trap_exit_without_handler,
        fields: [
          {:mod, :symbol, "module"},
          {:witness, :symbol, "function that sets trap_exit"}
        ],
        key: [:mod],
        doc: "Module traps exits but has no handle_info({:EXIT,...},_) callback."
      },
      %{
        name: :trap_exit_without_exit_clause,
        fields: [
          {:mod, :symbol, "module"},
          {:witness, :symbol, "function that sets trap_exit"}
        ],
        key: [:mod],
        doc: "Module traps exits and defines handle_info/2, but no clause matches {:EXIT, ...}."
      },
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
        name: :exit_in_callback,
        fields: [
          {:func, :symbol, "callback function"},
          {:target, :symbol, "exit target"}
        ],
        doc: "Explicit Process.exit/2 inside GenServer callback."
      },
      %{
        name: :ignored_start_result,
        fields: [
          {:func, :symbol, "calling function"},
          {:callee, :symbol, "start function"}
        ],
        doc: "GenServer/Supervisor start result not pattern matched."
      }
    ]
  end

  @impl true
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

  def finding(:partial_noproc_catch, [func, site, callee]) do
    Findings.new(
      :warning,
      "Peer call catches :noproc but not :shutdown",
      "#{func} wraps #{callee} in a catch for `{:noproc, _}` — the peer may not " <>
        "exist — but the peer stopping while the call is in flight is the same " <>
        "condition, and it arrives as `{:shutdown, _}` (or `{:normal, _}`), which " <>
        "this catch lets crash the caller.",
      at: Findings.at_site(site, func),
      at_label: "catches only :noproc",
      help: [
        "add a clause for `:exit, {:shutdown, _}` (and `{:normal, _}`)",
        "or catch `:exit, reason` and classify it"
      ]
    )
  end

  def finding(:swallowed_error, [func]) do
    Findings.new(
      :warning,
      "Catch-all rescue swallows exceptions",
      "#{func} rescues every exception without re-raising, logging, or " <>
        "matching specific types. Bugs become silence: the failure surfaces " <>
        "later, far from its cause, with the stacktrace gone. Rescue the " <>
        "specific exceptions you can actually handle.",
      at: Findings.at_func(func)
    )
  end

  def finding(:trap_exit_without_handler, [mod, witness]) do
    Findings.new(
      :warning,
      "trap_exit without an :EXIT handler",
      "#{mod} sets trap_exit but defines no handle_info({:EXIT, ...}, _) " <>
        "clause. Exit signals from linked processes arrive as plain mailbox " <>
        "messages and fall through to the default handle_info — a crash or a " <>
        "noisy log, exactly what trapping was meant to prevent.",
      at: Findings.at_func(witness)
    )
  end

  def finding(:trap_exit_without_exit_clause, [mod, witness]) do
    Findings.new(
      :warning,
      "trap_exit without an {:EXIT, ...} clause",
      "#{mod} sets trap_exit and defines handle_info/2, but no clause " <>
        "matches {:EXIT, pid, reason} and none is a catch-all. A trapped " <>
        "exit arrives as an ordinary message, and once handle_info/2 is " <>
        "defined an unmatched message is a FunctionClauseError — the " <>
        "process dies on the very signal trapping was meant to absorb, " <>
        "the first time anything it linked to exits.",
      at: Findings.at_func(witness),
      at_label: "exits are trapped here",
      help: [
        "add a `handle_info({:EXIT, pid, reason}, state)` clause that " <>
          "decides what a linked exit means for this process, or a " <>
          "catch-all `handle_info(_msg, state)` if none are expected"
      ],
      related: [Findings.related("handle_info/2", Findings.at_mfa(mod, :handle_info, 2))]
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

  def finding(:exit_in_callback, [func, target]) do
    Findings.new(
      :info,
      "Process.exit inside a GenServer callback",
      "#{func} sends an exit signal to #{target} from inside a callback. " <>
        "This is often deliberate — process-manager handoff, registry " <>
        "name-conflict resolution, an ownership watcher killing dependents — " <>
        "but killing a process imperatively bypasses the supervisor that " <>
        "started it, so it is worth confirming the target is meant to be " <>
        "torn down this way rather than stopped through its own protocol.",
      at: Findings.at_func(func)
    )
  end

  def finding(:ignored_start_result, [func, callee]) do
    Findings.new(
      :warning,
      "Start result ignored",
      "#{func} calls #{callee} and discards the result. An {:error, reason} " <>
        "return goes unnoticed — the process isn't running, and the first " <>
        "symptom is a crash later at a call site that assumed it was.",
      at: Findings.at_func(func)
    )
  end
end
