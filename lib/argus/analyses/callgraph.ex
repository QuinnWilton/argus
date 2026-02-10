defmodule Argus.Analyses.Callgraph do
  @moduledoc """
  Call graph analysis.

  Derives function-level call edges from local and remote call instructions.
  Edges connect caller function IDs to callee function IDs.

  ## Output relations

  - `call_edge(caller, callee)` — directed edge in the call graph.
  """

  @behaviour Argus.Analysis

  @impl true
  def name, do: :callgraph

  @impl true
  def description, do: "call graph edges"

  @impl true
  def rules_file, do: "callgraph.dl"

  @impl true
  def extractors, do: []

  @impl true
  def output_relations do
    [
      %{
        name: :call_edge,
        fields: [
          {:caller, :symbol, "caller function ID"},
          {:callee, :symbol, "callee function ID"}
        ],
        doc: "Directed edge in the call graph."
      }
    ]
  end
end
