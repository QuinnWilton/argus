defmodule Argus.Analyses.Liveness do
  @moduledoc """
  Live variable analysis.

  Computes which registers are live (will be read before being overwritten)
  at each program point. Also identifies dead definitions — writes to
  registers that are never subsequently read.

  ## Output relations

  - `live_in(id, reg)` — register is live at entry to an instruction.
  - `live_out(id, reg)` — register is live at exit from an instruction.
  - `dead_def(id, reg)` — register is defined but never used.
  """

  @behaviour Argus.Analysis

  @impl true
  def name, do: :liveness

  @impl true
  def description, do: "live variable analysis and dead definition detection"

  @impl true
  def rules_file, do: "liveness.dl"

  @impl true
  def extractors, do: []

  @impl true
  def output_relations do
    [
      %{
        name: :live_in,
        fields: [{:id, :symbol, "instruction ID"}, {:reg, :symbol, "register"}],
        doc: "Register is live at entry to an instruction."
      },
      %{
        name: :live_out,
        fields: [{:id, :symbol, "instruction ID"}, {:reg, :symbol, "register"}],
        doc: "Register is live at exit from an instruction."
      },
      %{
        name: :dead_def,
        fields: [{:id, :symbol, "instruction ID"}, {:reg, :symbol, "register"}],
        doc: "Register is defined but never used."
      }
    ]
  end
end
