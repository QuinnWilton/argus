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
  """

  @behaviour Argus.Analysis

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
end
