defmodule Argus.Analyses.SyncCallInInit do
  @moduledoc """
  Synchronous calls in init/1 detection.

  Identifies GenServer/Supervisor modules whose `init/1` callback makes
  synchronous calls (directly or transitively through the call graph). When
  combined with supervision ordering, detects guaranteed deadlocks: a child's
  init blocks on a sibling that hasn't started yet.

  Requires the OTP and Supervision extractors for `sync_call`,
  `implements_behaviour`, `supervisor`, and `supervisor_child` facts.

  ## Output relations

  - `sync_call_in_init(mod, callee_mod)` — module whose init/1 sync-calls callee_mod.
  - `init_deadlock_risk(sup, child, dep, child_pos, dep_pos)` — child's init calls a later-starting sibling.
  """

  @behaviour Argus.Analysis

  @impl true
  def name, do: :sync_call_in_init

  @impl true
  def description, do: "synchronous calls in init/1 (startup deadlock) detection"

  @impl true
  def rules_file, do: "sync_call_in_init.dl"

  @impl true
  def extractors, do: [Argus.Extractors.OTP, Argus.Extractors.Supervision]

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
end
