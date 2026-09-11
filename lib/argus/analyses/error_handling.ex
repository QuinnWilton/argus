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
  - `exit_in_callback(func, target)` — an exit *signal* (Process.exit/2)
    sent from a GenServer callback.
  - `ignored_start_result(func, callee)` — GenServer/Supervisor start result not checked.

  ## Finding severities

  `swallowed_error`, `trap_exit_without_handler`,
  `trap_exit_without_exit_clause` and `ignored_start_result` are
  `:warning`: each silently discards failure information — errors, exit
  signals, or failed starts — so the bug surfaces later, far from its
  cause. `handle_info_without_catchall` is `:info`: whether a stray
  message is worth crashing over is a judgement call, but the process
  has invited such messages. `exit_in_callback` is `:info`:
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
      Argus.Extractors.CallbackTag,
      Argus.Extractors.Monitor
    ]

  @impl true
  def output_relations do
    [
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
