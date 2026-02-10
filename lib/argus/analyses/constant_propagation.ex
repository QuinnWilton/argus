defmodule Argus.Analyses.ConstantPropagation do
  @moduledoc """
  Constant propagation and value tracking.

  Propagates literal values through move chains to determine which registers
  hold known constant values at each program point. Useful for resolving
  dynamic call targets, tracking atom values through pattern matches, and
  improving precision of downstream analyses.

  ## Output relations

  - `value_at(id, reg, val)` — register holds a known value at a program point.
  - `unique_value_at(id, reg, val)` — register holds exactly one value (constant).
  - `resolved_call_target(id, mod, func, arity)` — resolved call targets.
  - `constant_def(id, reg, val)` — instruction produces a constant value.
  """

  @behaviour Argus.Analysis

  @impl true
  def name, do: :constant_propagation

  @impl true
  def description, do: "constant propagation through move chains"

  @impl true
  def rules_file, do: "analyses/constant_propagation.dl"

  @impl true
  def extractors, do: []

  @impl true
  def output_relations do
    [
      %{
        name: :value_at,
        fields: [
          {:id, :symbol, "instruction ID"},
          {:reg, :symbol, "register"},
          {:val, :symbol, "constant value"}
        ],
        doc: "Register holds a known value at a program point."
      },
      %{
        name: :unique_value_at,
        fields: [
          {:id, :symbol, "instruction ID"},
          {:reg, :symbol, "register"},
          {:val, :symbol, "constant value"}
        ],
        doc: "Register holds exactly one constant value at a program point."
      },
      %{
        name: :resolved_call_target,
        fields: [
          {:id, :symbol, "instruction ID"},
          {:mod, :symbol, "resolved module"},
          {:func, :symbol, "resolved function"},
          {:arity, :number, "call arity"}
        ],
        doc: "Call with resolved target (either statically known or via constant propagation)."
      },
      %{
        name: :constant_def,
        fields: [
          {:id, :symbol, "instruction ID"},
          {:reg, :symbol, "register"},
          {:val, :symbol, "constant value"}
        ],
        doc: "Instruction that produces a constant value."
      }
    ]
  end
end
