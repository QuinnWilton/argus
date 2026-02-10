defmodule Argus.Analyses.ReachingDef do
  @moduledoc """
  Reaching definitions analysis.

  Computes which register definitions reach each program point and builds
  def-use chains linking each definition to its uses. A classic dataflow
  analysis useful for understanding data dependencies.

  ## Output relations

  - `reaching_def(def_id, reg, point)` — definition reaches a program point.
  - `def_use(def_id, use_id, reg)` — definition-use chain for a register.
  """

  @behaviour Argus.Analysis

  @impl true
  def name, do: :reaching_def

  @impl true
  def description, do: "reaching definitions and def-use chains"

  @impl true
  def rules_file, do: "analyses/reaching_def.dl"

  @impl true
  def extractors, do: []

  @impl true
  def output_relations do
    [
      %{
        name: :reaching_def,
        fields: [
          {:def_id, :symbol, "defining instruction ID"},
          {:reg, :symbol, "defined register"},
          {:point, :symbol, "program point reached"}
        ],
        doc: "Definition of a register that reaches a program point."
      },
      %{
        name: :def_use,
        fields: [
          {:def_id, :symbol, "defining instruction ID"},
          {:use_id, :symbol, "using instruction ID"},
          {:reg, :symbol, "register"}
        ],
        doc: "Definition-use chain linking a def to its use."
      }
    ]
  end
end
