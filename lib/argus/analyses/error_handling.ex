defmodule Argus.Analyses.ErrorHandling do
  @moduledoc """
  Error handling analysis.

  Detects error handling anti-patterns: bare rescues that silently swallow
  exceptions, trap_exit without matching handler, exit calls in GenServer
  callbacks, and ignored start results.

  ## Output relations

  - `swallowed_error(func)` — catch-all rescue that silently discards exceptions.
  - `trap_exit_without_handler(mod)` — traps exits but no handle_info({:EXIT,...},_) callback.
  - `exit_in_callback(func, target)` — explicit Process.exit/2 inside GenServer callback.
  - `ignored_start_result(func, callee)` — GenServer/Supervisor start result not checked.

  ## Finding severities

  All four relations are `:warning`: each silently discards failure
  information — errors, exit signals, or failed starts — so the bug
  surfaces later, far from its cause.
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
  def extractors, do: [Argus.Extractors.ErrorHandling, Argus.Extractors.OTP]

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
        fields: [{:mod, :symbol, "module"}],
        doc: "Module traps exits but has no handle_info({:EXIT,...},_) callback."
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

  def finding(:trap_exit_without_handler, [mod]) do
    Findings.new(
      :warning,
      "trap_exit without an :EXIT handler",
      "#{mod} sets trap_exit but defines no handle_info({:EXIT, ...}, _) " <>
        "clause. Exit signals from linked processes arrive as plain mailbox " <>
        "messages and fall through to the default handle_info — a crash or a " <>
        "noisy log, exactly what trapping was meant to prevent.",
      at: Findings.at_module(mod)
    )
  end

  def finding(:exit_in_callback, [func, target]) do
    Findings.new(
      :warning,
      "Process.exit inside a GenServer callback",
      "#{func} calls Process.exit on #{target} from inside a callback. " <>
        "Killing processes imperatively bypasses supervision: the target's " <>
        "supervisor sees an abnormal exit it didn't orchestrate, and restart " <>
        "intensity accounting absorbs a failure that was really control flow.",
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
