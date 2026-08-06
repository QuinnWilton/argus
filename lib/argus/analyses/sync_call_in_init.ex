defmodule Argus.Analyses.SyncCallInInit do
  @moduledoc """
  Synchronous calls in init/1 detection.

  Identifies GenServer/Supervisor modules whose `init/1` callback makes
  synchronous calls (directly or transitively through the call graph). When
  combined with supervision ordering, detects guaranteed deadlocks: a child's
  init blocks on a sibling that hasn't started yet.

  Supervision-aware filtering removes proven-safe findings:

  - **Safe sibling**: the callee starts earlier under the same supervisor,
    so it is already running when the caller's `init/1` executes.
  - **Safe cross-supervisor**: the caller and callee are under disjoint
    supervisor trees, so the callee was started by a different supervisor
    and is already running.

  Requires the OTP and Supervision extractors for `sync_call`,
  `implements_behaviour`, `supervisor`, and `supervisor_child` facts.

  ## Output relations

  - `sync_call_in_init(mod, callee_mod)` — module whose init/1 sync-calls callee_mod (after filtering proven-safe cases).
  - `init_deadlock_risk(sup, child, dep, child_pos, dep_pos)` — child's init calls a later-starting sibling.

  ## Finding severities

  - `sync_call_in_init` — `:warning`. The target's liveness couldn't be
    proven either way; the call stalls startup whenever the target is
    slow or absent.
  - `init_deadlock_risk` — `:error`. Supervisors start children in order
    and `init/1` blocks that sequence, so an init that waits on a
    later-starting sibling is a deadlock by construction.
  """

  @behaviour Argus.Analysis

  alias Argus.Findings

  @impl true
  def name, do: :sync_call_in_init

  @impl true
  def description, do: "synchronous calls in init/1 (startup deadlock) detection"

  @impl true
  def rules_file, do: "analyses/sync_call_in_init.dl"

  @impl true
  def extractors,
    do: [
      Argus.Extractors.OTP,
      Argus.Extractors.Supervision,
      Argus.Extractors.GenEvent,
      Argus.Extractors.CallbackTag,
      Argus.Extractors.Literal,
      # sync_call_in_init's rules reach `sync_call` through
      # clientlib/interprocedural.dl, which resolves a target module
      # forwarded through a wrapper — `defp fetch(server), do:
      # GenServer.call(server, ...)` called from init with a literal.
      # Nothing declared CallArgs, so call_arg and call_arg_forward were
      # empty and that resolution never ran.
      Argus.Extractors.CallArgs
    ]

  @impl true
  def output_relations do
    [
      %{
        name: :sync_call_in_init,
        fields: [
          {:mod, :symbol, "module whose init/1 makes a sync call"},
          {:callee, :symbol, "target module of the sync call"}
        ],
        doc: "Module whose init/1 transitively makes a synchronous call."
      },
      %{
        name: :init_deadlock_risk,
        fields: [
          {:sup, :symbol, "supervisor module"},
          {:child, :symbol, "child module whose init calls dep"},
          {:dep, :symbol, "dependency module (starts later)"},
          {:child_pos, :number, "child start position"},
          {:dep_pos, :number, "dependency start position"}
        ],
        doc: "Child's init sync-calls a sibling that starts later."
      }
    ]
  end

  @impl true
  def finding(:sync_call_in_init, [mod, callee]) do
    Findings.new(
      :warning,
      "init/1 blocks on a synchronous call",
      "#{mod}.init/1 makes a synchronous call to #{callee} (directly or " <>
        "transitively). init runs inside the supervisor's start sequence, so " <>
        "the whole tree's startup stalls whenever #{callee} is slow, absent, " <>
        "or not yet started.",
      at: Findings.at_mfa(mod, :init, 1),
      at_label: "this init blocks the start sequence",
      help: [
        "defer the call to `handle_continue/2`: return " <>
          "`{:ok, state, {:continue, :finish_init}}` from init and make the " <>
          "call in `handle_continue(:finish_init, state)`"
      ],
      related: [Findings.related("call target", Findings.at_module(callee))]
    )
  end

  def finding(:init_deadlock_risk, [sup, child, dep, child_pos, dep_pos]) do
    Findings.new(
      :error,
      "Startup deadlock: init waits on a later sibling",
      "#{child} (position #{child_pos}) blocks in init/1 on #{dep}, which " <>
        "#{sup} only starts later (position #{dep_pos}). The supervisor " <>
        "cannot reach #{dep} until #{child}'s init returns, and #{child}'s " <>
        "init cannot return until #{dep} answers — the tree never finishes " <>
        "booting.",
      at: Findings.at_mfa(child, :init, 1),
      at_label: "this init blocks the start sequence",
      help: [
        "start `#{dep}` before `#{child}` in `#{sup}`'s child list " <>
          "(supervisors start children in order), or defer the call to " <>
          "`handle_continue/2`"
      ],
      related: [
        Findings.related("supervisor", Findings.at_module(sup)),
        Findings.related("later dependency", Findings.at_module(dep))
      ]
    )
  end
end
