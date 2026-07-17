defmodule Argus.Analyses.Supervision do
  @moduledoc """
  Supervision tree analysis.

  Detects anti-patterns in supervision tree structure: transient processes
  depended on by permanent ones, and children started in the wrong order
  relative to their dependencies. Cross-branch coupling under one_for_one
  is the `one_for_one_coupling` analysis's job — the two do not overlap.

  Requires the supervision and OTP domain extractors for layer 2 facts
  about supervisor children, restart strategies, and behaviour implementations.

  ## Output relations

  - `suspect_transient_dependency(sup, permanent, transient, sup_site, witness)` — permanent child depends on transient sibling.
  - `wrong_start_order(sup, child, dep, child_pos, dep_pos, sup_site, witness)` — child starts before its dependency.

  ## Finding severities

  Both relations are `:warning`: each is a structural hazard that
  bites during crash/restart windows rather than a guaranteed failure in
  steady state.
  """

  @behaviour Argus.Analysis

  alias Argus.Findings

  @impl true
  def name, do: :supervision

  @impl true
  def description, do: "supervision tree structure and anti-patterns"

  @impl true
  def rules_file, do: "analyses/supervision.dl"

  @impl true
  def extractors,
    do: [Argus.Extractors.Supervision, Argus.Extractors.OTP, Argus.Extractors.GenEvent]

  @impl true
  def output_relations do
    [
      %{
        name: :suspect_transient_dependency,
        fields: [
          {:sup, :symbol, "supervisor module"},
          {:permanent, :symbol, "permanent child module"},
          {:transient, :symbol, "transient child module"},
          {:sup_site, :symbol, "instruction ID of the tree definition"},
          {:witness, :symbol, "function in the permanent child carrying the dependency"}
        ],
        key: [:sup, :permanent, :transient],
        doc: "Permanent child depends on a transient sibling."
      },
      %{
        name: :wrong_start_order,
        fields: [
          {:sup, :symbol, "supervisor module"},
          {:child, :symbol, "child module"},
          {:dep, :symbol, "dependency module"},
          {:child_pos, :number, "child start position"},
          {:dep_pos, :number, "dependency start position"},
          {:sup_site, :symbol, "instruction ID of the tree definition"},
          {:witness, :symbol, "the child's init/1, where the call originates"}
        ],
        key: [:sup, :child, :dep],
        doc: "Child starts before its dependency."
      }
    ]
  end

  # These defects live in the supervisor's composition — strategy and
  # child order — so findings anchor at the tree definition (where the
  # fix goes) and the dependency's call path becomes labelled evidence.
  @impl true
  def finding(:suspect_transient_dependency, [sup, permanent, transient, sup_site, witness]) do
    Findings.new(
      :warning,
      "Permanent child depends on a transient sibling",
      "#{permanent} is a permanent child of #{sup} but depends on its transient " <>
        "sibling #{transient}. A transient child that stops normally is never " <>
        "restarted, so #{permanent} keeps running against a process that no " <>
        "longer exists.",
      at: Findings.at_site(sup_site, sup),
      related: [
        Findings.related("dependency call", Findings.at_func(witness)),
        Findings.related("transient sibling", Findings.at_module(transient))
      ]
    )
  end

  def finding(:wrong_start_order, [sup, child, dep, child_pos, dep_pos, sup_site, witness]) do
    Findings.new(
      :warning,
      "Child starts before its dependency",
      "#{child} (position #{child_pos}) starts before #{dep} (position #{dep_pos}) " <>
        "under #{sup}, yet depends on it. During startup, #{child} can run while " <>
        "#{dep} is not yet alive — calls into it fail until the tree finishes " <>
        "booting.",
      at: Findings.at_site(sup_site, sup),
      related: [
        Findings.related("init-time call", Findings.at_func(witness)),
        Findings.related("dependency", Findings.at_module(dep))
      ]
    )
  end
end
