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
  - `init_timeout_deferral(mod, site, timeout_ms)` — init/1 returns
    `{:ok, state, timeout}`; the work behind `:timeout` is cancelled by
    any message that arrives first.

  ## Finding severities

  - `mutual_continue_deadlock` — `:error`. Both processes block before
    ever reading their mailboxes; neither can answer the other, by
    construction.
  - `init_timeout_deferral` — `:info`. Whether the deferred work is
    load-bearing is the reader's call; the shape is fragile either way.
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
    do: [
      Argus.Extractors.CallbackTag,
      Argus.Extractors.OTP,
      Argus.Extractors.ApiCalls,
      Argus.Extractors.Supervision,
      Argus.Extractors.Reply,
      # See sync_call_in_init: `sync_call` is partly derived by
      # clientlib/interprocedural.dl, which needs call_arg and
      # call_arg_forward to resolve a target forwarded through a wrapper.
      Argus.Extractors.CallArgs
    ]

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
        name: :init_timeout_deferral,
        fields: [
          {:mod, :symbol, "module whose init/1 returns a timeout"},
          {:site, :symbol, "the return site"},
          {:timeout_ms, :number, "the literal timeout"}
        ],
        doc:
          "init/1 returns {:ok, state, timeout}: deferred work that any earlier message cancels."
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
      at_label: "one side of the cycle blocks here",
      help: [
        "break the cycle: keep one direction synchronous and make the other " <>
          "asynchronous (a cast, or a message each side processes once both " <>
          "are up)"
      ],
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
      at_label: "the racing call originates here",
      help: [
        "start `#{callee}` before `#{caller}` in `#{sup}`'s child list, or " <>
          "make `#{caller}` tolerate `#{callee}`'s absence (retry with " <>
          "backoff, or monitor and wait for it to register)"
      ],
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
      at_label: "calls the parent supervisor here",
      help: [
        "move the supervisor query out of startup: pass the information as " <>
          "an init argument, or query later from a message sent once the " <>
          "tree is up"
      ],
      related: [Findings.related("parent supervisor", Findings.at_module(sup))]
    )
  end

  def finding(:init_timeout_deferral, [mod, site, "0"]) do
    Findings.new(
      :info,
      "init/1 defers work with a zero timeout",
      "#{mod}.init/1 returns {:ok, state, 0}, the pre-handle_continue " <>
        "idiom for finishing initialisation once the supervisor has moved " <>
        "on. The :timeout message only arrives if nothing else is in the " <>
        "mailbox first: any message — a datagram on a socket init opened, " <>
        "a PubSub broadcast init subscribed to, a call from the starter — " <>
        "cancels it, and the deferred work silently never runs.",
      at: Findings.at_site(site, mod),
      at_label: "this timeout is cancelled by any earlier message",
      help: [
        "return `{:ok, state, {:continue, :finish_init}}` and move the work " <>
          "to `handle_continue(:finish_init, state)`, which runs before any " <>
          "message is processed"
      ]
    )
  end

  def finding(:init_timeout_deferral, [mod, site, ms]) do
    Findings.new(
      :info,
      "init/1 relies on a #{ms}ms idle timeout",
      "#{mod}.init/1 returns {:ok, state, #{ms}}. The :timeout message " <>
        "fires only after #{ms}ms of an empty mailbox, and every message " <>
        "that arrives restarts nothing — the callback must return the " <>
        "timeout again or it is gone. If the work behind :timeout must " <>
        "happen, a timer (Process.send_after/3) or handle_continue/2 is " <>
        "the reliable shape; an idle timeout is for reacting to silence.",
      at: Findings.at_site(site, mod),
      at_label: "this timeout is cancelled by any earlier message"
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
      at_label: "the defensive catch hides the race here",
      help: [
        "remove the try/catch and fix the ordering it papers over: start the " <>
          "callee earlier in the child list, or retry the call with backoff " <>
          "until the callee is up"
      ],
      related: [Findings.related("supervisor", Findings.at_module(sup))]
    )
  end
end
