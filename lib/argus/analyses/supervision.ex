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
  """

  @behaviour Argus.Analysis

  @impl true
  def name, do: :supervision

  @impl true
  def description, do: "supervision tree structure and anti-patterns"

  @impl true
  def rules_file, do: "analyses/supervision.dl"

  @impl true
  def extractors, do: [Argus.Extractors.Supervision, Argus.Extractors.OTP]

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
end
