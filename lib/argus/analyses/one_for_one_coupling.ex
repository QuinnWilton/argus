defmodule Argus.Analyses.OneForOneCoupling do
  @moduledoc """
  One-for-one coupling analysis.

  Detects cross-branch coupling under one_for_one supervisors: when one child
  calls another's API, a crash of the callee won't restart the caller, leaving
  it with a stale reference. Also detects children started in the wrong order
  relative to their call dependencies.

  Requires the supervision and OTP domain extractors for layer 2 facts
  about supervisor children and inter-process communication.

  ## Output relations

  - `one_for_one_coupling(sup, caller_mod, callee_mod)` — cross-branch coupling under one_for_one.
  - `wrong_start_order(sup, early_mod, late_mod, early_pos, late_pos)` — dependency starts after dependent.
  """

  @behaviour Argus.Analysis

  @impl true
  def name, do: :one_for_one_coupling

  @impl true
  def description, do: "cross-branch coupling under one_for_one supervisors"

  @impl true
  def rules_file, do: "one_for_one_coupling.dl"

  @impl true
  def extractors, do: [Argus.Extractors.Supervision, Argus.Extractors.OTP]

  @impl true
  def output_relations do
    [
      %{
        name: :one_for_one_coupling,
        fields: [
          {:sup, :symbol, "supervisor module"},
          {:caller_mod, :symbol, "calling child module"},
          {:callee_mod, :symbol, "called child module"}
        ],
        doc: "Cross-branch coupling under a one_for_one supervisor."
      },
      %{
        name: :wrong_start_order,
        fields: [
          {:sup, :symbol, "supervisor module"},
          {:early_mod, :symbol, "module started early"},
          {:late_mod, :symbol, "module started late"},
          {:early_pos, :number, "early child position"},
          {:late_pos, :number, "late child position"}
        ],
        doc: "Dependency starts after the child that depends on it."
      }
    ]
  end
end
