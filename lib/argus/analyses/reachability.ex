defmodule Argus.Analyses.Reachability do
  @moduledoc """
  Transitive reachability analysis.

  Computes the transitive closure over both the control flow graph
  (instruction-level) and the call graph (function-level). Useful for
  answering "can point A reach point B?" queries.

  ## Output relations

  - `cfg_edge(from, to)` — direct CFG edges (included from cfg rules).
  - `call_edge(caller, callee)` — direct call graph edges.
  - `cfg_reachable(from, to)` — transitive CFG reachability.
  - `call_reachable(from, to)` — transitive call graph reachability.
  """

  @behaviour Argus.Analysis

  @impl true
  def name, do: :reachability

  @impl true
  def description, do: "transitive CFG and call reachability"

  @impl true
  def rules_file, do: "analyses/reachability.dl"

  @impl true
  def extractors, do: []

  @impl true
  def output_relations do
    [
      %{
        name: :cfg_edge,
        fields: [
          {:from, :symbol, "source instruction ID"},
          {:to, :symbol, "target instruction ID"}
        ],
        doc: "Direct control flow graph edge."
      },
      %{
        name: :call_edge,
        fields: [
          {:caller, :symbol, "caller function ID"},
          {:callee, :symbol, "callee function ID"}
        ],
        doc: "Direct call graph edge."
      },
      %{
        name: :cfg_reachable,
        fields: [
          {:from, :symbol, "source instruction ID"},
          {:to, :symbol, "reachable instruction ID"}
        ],
        doc: "Transitive CFG reachability."
      },
      %{
        name: :call_reachable,
        fields: [{:from, :symbol, "source function ID"}, {:to, :symbol, "reachable function ID"}],
        doc: "Transitive call graph reachability."
      }
    ]
  end
end
