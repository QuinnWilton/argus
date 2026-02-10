defmodule Argus.Analyses.TailCall do
  @moduledoc """
  Tail call analysis.

  Identifies tail calls, non-tail calls, direct recursion patterns, and
  functions at risk of stack growth from non-tail-recursive loops.

  ## Output relations

  - `has_tail_call(func)` — function contains at least one tail call.
  - `has_non_tail_call(func, callee)` — function makes a non-tail call.
  - `direct_recursion(func, is_tail)` — function calls itself (is_tail: "yes"/"no").
  - `stack_growth_risk(func)` — function recurses without tail calls.
  """

  @behaviour Argus.Analysis

  @impl true
  def name, do: :tail_call

  @impl true
  def description, do: "tail call identification and recursion detection"

  @impl true
  def rules_file, do: "analyses/tail_call.dl"

  @impl true
  def extractors, do: []

  @impl true
  def output_relations do
    [
      %{
        name: :has_tail_call,
        fields: [{:func, :symbol, "function ID"}],
        doc: "Function contains at least one tail call."
      },
      %{
        name: :has_non_tail_call,
        fields: [{:func, :symbol, "function ID"}, {:callee, :symbol, "callee function ID"}],
        doc: "Function makes a non-tail call to callee."
      },
      %{
        name: :direct_recursion,
        fields: [{:func, :symbol, "function ID"}, {:is_tail, :symbol, "\"yes\" or \"no\""}],
        doc: "Function calls itself directly."
      },
      %{
        name: :stack_growth_risk,
        fields: [{:func, :symbol, "function ID"}],
        doc: "Function recurses without tail calls, risking stack growth."
      }
    ]
  end
end
