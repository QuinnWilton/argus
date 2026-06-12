defmodule Argus.Analyses.Supervision do
  @moduledoc """
  Supervision tree analysis.

  Detects anti-patterns in supervision tree structure: transient processes
  depended on by permanent ones, siblings that communicate but aren't linked,
  and children started in the wrong order relative to their dependencies.

  Requires the supervision and OTP domain extractors for layer 2 facts
  about supervisor children, restart strategies, and behaviour implementations.

  ## Output relations

  - `suspect_transient_dependency(sup, permanent, transient)` — permanent child depends on transient sibling.
  - `unlinked_coupled_siblings(sup, a, b)` — siblings communicate but lack linking.
  - `wrong_start_order(sup, child, dep, child_pos, dep_pos)` — child starts before its dependency.

  ## Finding severities

  All three relations are `:warning`: each is a structural hazard that
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
          {:transient, :symbol, "transient child module"}
        ],
        doc: "Permanent child depends on a transient sibling."
      },
      %{
        name: :unlinked_coupled_siblings,
        fields: [
          {:sup, :symbol, "supervisor module"},
          {:a, :symbol, "first sibling module"},
          {:b, :symbol, "second sibling module"}
        ],
        doc: "Siblings communicate but are not linked."
      },
      %{
        name: :wrong_start_order,
        fields: [
          {:sup, :symbol, "supervisor module"},
          {:child, :symbol, "child module"},
          {:dep, :symbol, "dependency module"},
          {:child_pos, :number, "child start position"},
          {:dep_pos, :number, "dependency start position"}
        ],
        doc: "Child starts before its dependency."
      }
    ]
  end

  @impl true
  def finding(:suspect_transient_dependency, [sup, permanent, transient]) do
    Findings.new(
      :warning,
      "Permanent child depends on a transient sibling",
      "#{permanent} is a permanent child of #{sup} but depends on its transient " <>
        "sibling #{transient}. A transient child that stops normally is never " <>
        "restarted, so #{permanent} keeps running against a process that no " <>
        "longer exists.",
      at: Findings.at_module(permanent),
      related: [
        Findings.related("supervisor", Findings.at_module(sup)),
        Findings.related("transient sibling", Findings.at_module(transient))
      ]
    )
  end

  def finding(:unlinked_coupled_siblings, [sup, a, b]) do
    Findings.new(
      :warning,
      "Coupled siblings without failure linking",
      "#{a} and #{b} communicate but are independent children of #{sup}. When one " <>
        "crashes, the other keeps running with stale state or dead references " <>
        "instead of restarting with it — rest_for_one or one_for_all would " <>
        "restart them together.",
      at: Findings.at_module(a),
      related: [
        Findings.related("supervisor", Findings.at_module(sup)),
        Findings.related("coupled sibling", Findings.at_module(b))
      ]
    )
  end

  def finding(:wrong_start_order, [sup, child, dep, child_pos, dep_pos]) do
    Findings.new(
      :warning,
      "Child starts before its dependency",
      "#{child} (position #{child_pos}) starts before #{dep} (position #{dep_pos}) " <>
        "under #{sup}, yet depends on it. During startup, #{child} can run while " <>
        "#{dep} is not yet alive — calls into it fail until the tree finishes " <>
        "booting.",
      at: Findings.at_module(child),
      related: [
        Findings.related("supervisor", Findings.at_module(sup)),
        Findings.related("dependency", Findings.at_module(dep))
      ]
    )
  end
end
