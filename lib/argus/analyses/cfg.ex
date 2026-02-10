defmodule Argus.Analyses.Cfg do
  @moduledoc """
  Control flow graph analysis.

  Derives intra-function control flow edges from branch, jump, select, and
  fallthrough instructions. Each edge connects two instruction IDs within the
  same function.

  ## Output relations

  - `cfg_edge(from, to)` — directed edge in the control flow graph.
  """

  @behaviour Argus.Analysis

  @impl true
  def name, do: :cfg

  @impl true
  def description, do: "control flow graph edges"

  @impl true
  def rules_file, do: "analyses/cfg.dl"

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
        doc: "Directed edge in the control flow graph."
      }
    ]
  end
end
