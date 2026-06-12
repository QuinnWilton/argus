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

  ## Finding severities

  Both relations are `:warning`: restart isolation and ordering hazards
  surface as stale references and failed calls during crash/boot windows,
  not as immediate failures.
  """

  @behaviour Argus.Analysis

  alias Argus.Findings

  @impl true
  def name, do: :one_for_one_coupling

  @impl true
  def description, do: "cross-branch coupling under one_for_one supervisors"

  @impl true
  def rules_file, do: "analyses/one_for_one_coupling.dl"

  @impl true
  def extractors,
    do: [Argus.Extractors.Supervision, Argus.Extractors.OTP, Argus.Extractors.GenEvent]

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

  @impl true
  def finding(:one_for_one_coupling, [sup, caller_mod, callee_mod]) do
    Findings.new(
      :warning,
      "Coupled children under one_for_one",
      "#{caller_mod} calls #{callee_mod}, but both are children of the " <>
        "one_for_one supervisor #{sup}. When #{callee_mod} crashes and " <>
        "restarts, #{caller_mod} is not restarted with it and keeps any " <>
        "stale pid, monitor, or cached state it held.",
      at: Findings.at_module(caller_mod),
      related: [
        Findings.related("supervisor", Findings.at_module(sup)),
        Findings.related("called sibling", Findings.at_module(callee_mod))
      ]
    )
  end

  def finding(:wrong_start_order, [sup, early_mod, late_mod, early_pos, late_pos]) do
    Findings.new(
      :warning,
      "Child starts before the sibling it calls",
      "#{early_mod} (position #{early_pos}) starts before #{late_mod} " <>
        "(position #{late_pos}) under #{sup}, yet calls it. Until the tree " <>
        "finishes booting, those calls target a process that does not exist " <>
        "yet.",
      at: Findings.at_module(early_mod),
      related: [
        Findings.related("supervisor", Findings.at_module(sup)),
        Findings.related("later dependency", Findings.at_module(late_mod))
      ]
    )
  end
end
