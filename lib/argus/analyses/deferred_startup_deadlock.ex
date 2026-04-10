defmodule Argus.Analyses.DeferredStartupDeadlock do
  @moduledoc """
  Deferred startup deadlock detection.

  `handle_continue/2` runs after `init/1` returns, so a sync call from
  inside `handle_continue` does NOT block the parent supervisor — that's
  why this is a separate analysis from `sync_call_in_init`. But three
  specific patterns make handle_continue sync calls genuinely problematic:

  1. **Mutual continue cycle** — `A.handle_continue` sync-calls `B`,
     `B.handle_continue` sync-calls `A`. Both processes return from init,
     the supervisor proceeds, but neither child ever processes its
     mailbox.
  2. **Continue calls later sibling** — under `:one_for_one`, calling a
     sibling that starts at a later position in the supervisor's child
     list races against that sibling's startup.
  3. **Continue calls parent supervisor** — calling
     `Supervisor.which_children/1` on the parent while it's still
     mid-`start_link`. The supervisor isn't reading its mailbox yet.

  Plus a defensive variant: when the continue body is wrapped in
  `try/catch :exit, _`, the literal deadlock is suppressed but the
  worker enters a supervisor restart loop.

  ## Output relations

  - `mutual_continue_deadlock(mod_a, mod_b)` — both modules' continues
    sync-call each other.
  - `continue_to_later_sibling(sup, caller, callee, caller_pos, callee_pos)`
    — caller's continue sync-calls a sibling started later in the same
    supervisor.
  - `continue_to_parent_supervisor(worker, sup)` — worker's continue
    sync-calls back into its parent supervisor.
  - `continue_crash_loop_risk(sup, worker)` — defensive try/catch around
    the call converts the deadlock into a supervisor restart loop.
  """

  @behaviour Argus.Analysis

  @impl true
  def name, do: :deferred_startup_deadlock

  @impl true
  def description, do: "handle_continue deadlock and crash-loop detection"

  @impl true
  def rules_file, do: "analyses/deferred_startup_deadlock.dl"

  @impl true
  def extractors,
    do: [Argus.Extractors.OTP, Argus.Extractors.Supervision, Argus.Extractors.GenEvent]

  @impl true
  def output_relations do
    [
      %{
        name: :mutual_continue_deadlock,
        fields: [
          {:mod_a, :symbol, "first module in the mutual cycle"},
          {:mod_b, :symbol, "second module in the mutual cycle"}
        ],
        doc:
          "Two modules whose handle_continue clauses sync-call each other — both children stay alive but neither processes its mailbox."
      },
      %{
        name: :continue_to_later_sibling,
        fields: [
          {:sup, :symbol, "supervisor module"},
          {:caller, :symbol, "child whose handle_continue makes the call"},
          {:callee, :symbol, "later-started sibling being called"},
          {:caller_pos, :number, "caller's start position in the supervisor"},
          {:callee_pos, :number, "callee's start position in the supervisor"}
        ],
        doc:
          "handle_continue races against a sibling started at a later position in the same supervisor's child list."
      },
      %{
        name: :continue_to_parent_supervisor,
        fields: [
          {:worker, :symbol, "worker whose handle_continue makes the call"},
          {:sup, :symbol, "the parent supervisor being called"}
        ],
        doc:
          "handle_continue calls back into the parent supervisor while it's still mid-start_link."
      },
      %{
        name: :continue_crash_loop_risk,
        fields: [
          {:sup, :symbol, "supervisor module"},
          {:worker, :symbol, "worker module with defensive try/catch around the continue call"}
        ],
        doc:
          "Defensive try/catch :exit suppresses the literal deadlock but creates a supervisor restart loop."
      }
    ]
  end
end
