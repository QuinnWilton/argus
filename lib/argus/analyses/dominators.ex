defmodule Argus.Analyses.Dominators do
  @moduledoc """
  Dominator and post-dominator analysis.

  Computes instruction-level dominance within each function's control flow
  graph using a negation-based approach: instruction A dominates B iff every
  path from the function entry to B passes through A.

  Also computes post-dominators (every path from B to an exit passes through
  A) and immediate dominators (closest strict dominator in the dominator tree).

  ## Output relations

  - `dominates(dominator, id, func)` — strict dominance within a function.
  - `post_dominates(post_dominator, id, func)` — strict post-dominance.
  - `idom(id, immediate_dominator, func)` — immediate dominator tree edge.
  """

  @behaviour Argus.Analysis

  @impl true
  def name, do: :dominators

  @impl true
  def description, do: "dominator and post-dominator analysis"

  @impl true
  def rules_file, do: "analyses/dominators.dl"

  @impl true
  def extractors, do: []

  @impl true
  def output_relations do
    [
      %{
        name: :dominates,
        fields: [
          {:dominator, :symbol, "dominating instruction ID"},
          {:id, :symbol, "dominated instruction ID"},
          {:func, :symbol, "containing function ID"}
        ],
        doc: "Instruction A strictly dominates instruction B within a function."
      },
      %{
        name: :post_dominates,
        fields: [
          {:post_dominator, :symbol, "post-dominating instruction ID"},
          {:id, :symbol, "post-dominated instruction ID"},
          {:func, :symbol, "containing function ID"}
        ],
        doc: "Instruction A strictly post-dominates instruction B within a function."
      },
      %{
        name: :idom,
        fields: [
          {:id, :symbol, "instruction ID"},
          {:immediate_dominator, :symbol, "immediate dominator instruction ID"},
          {:func, :symbol, "containing function ID"}
        ],
        doc: "Immediate dominator tree edge."
      }
    ]
  end
end
