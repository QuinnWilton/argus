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

  ## Finding severities

  - `mutual_continue_deadlock` — `:error`. Both processes block before
    ever reading their mailboxes; neither can answer the other, by
    construction.
  - `continue_to_later_sibling`, `continue_to_parent_supervisor`,
    `continue_crash_loop_risk` — `:warning`. Startup races and restart
    loops whose outcome depends on timing rather than being guaranteed
    on every boot.
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

  alias Argus.Findings

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

  @impl true
  def finding(:mutual_continue_deadlock, [mod_a, mod_b]) do
    Findings.new(
      :error,
      "Mutual handle_continue deadlock",
      "#{mod_a} and #{mod_b} sync-call each other from handle_continue/2. " <>
        "Both return from init — the supervisor proceeds happily — then each " <>
        "blocks calling the other before ever reading its own mailbox. " <>
        "Neither can reply; both calls time out, forever, on every boot.",
      at: Findings.at_mfa(mod_a, :handle_continue, 2),
      related: [Findings.related("cycle partner", Findings.at_mfa(mod_b, :handle_continue, 2))]
    )
  end

  def finding(:continue_to_later_sibling, [sup, caller, callee, caller_pos, callee_pos]) do
    Findings.new(
      :warning,
      "handle_continue races a later sibling",
      "#{caller} (position #{caller_pos}) sync-calls #{callee} (position " <>
        "#{callee_pos}) from handle_continue under #{sup}. The continue runs " <>
        "concurrently with the supervisor's start sequence, so whether " <>
        "#{callee} is alive when the call lands is a boot-time race — it " <>
        "works on the fast machine and fails in CI.",
      at: Findings.at_mfa(caller, :handle_continue, 2),
      related: [
        Findings.related("supervisor", Findings.at_module(sup)),
        Findings.related("later sibling", Findings.at_module(callee))
      ]
    )
  end

  def finding(:continue_to_parent_supervisor, [worker, sup]) do
    Findings.new(
      :warning,
      "handle_continue calls its own supervisor",
      "#{worker}'s handle_continue sync-calls its parent #{sup} while the " <>
        "supervisor may still be mid-start_link, not yet reading its mailbox. " <>
        "The worker blocks until the whole child list finishes starting — and " <>
        "if any later child waits on #{worker}, startup deadlocks.",
      at: Findings.at_mfa(worker, :handle_continue, 2),
      related: [Findings.related("parent supervisor", Findings.at_module(sup))]
    )
  end

  def finding(:continue_crash_loop_risk, [sup, worker]) do
    Findings.new(
      :warning,
      "Defensive continue turns deadlock into a restart loop",
      "#{worker} wraps its handle_continue sync call in try/catch :exit. The " <>
        "catch suppresses the deadlock symptom, but the call still fails " <>
        "during the startup race — so #{worker} either initializes with wrong " <>
        "state or crashes and restarts repeatedly under #{sup}, hiding the " <>
        "real ordering bug.",
      at: Findings.at_mfa(worker, :handle_continue, 2),
      related: [Findings.related("supervisor", Findings.at_module(sup))]
    )
  end
end
