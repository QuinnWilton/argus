defmodule Argus.Analyses.FunctionSummary do
  @moduledoc """
  Function summary analysis.

  Identifies small wrapper and delegate functions and computes their effective
  call targets. When a function's body just forwards to another function
  (common in Elixir for GenServer wrappers, pipeline helpers, etc.), this
  analysis determines what calling that function effectively does.

  ## Output relations

  - `function_summary_call(func, target_mod, target_func, target_arity)` —
    calling func effectively calls the target.
  - `tail_call_delegate(func, target_mod, target_func, target_arity)` —
    delegate whose call is in tail position.
  - `transitive_summary(func, target_mod, target_func, target_arity)` —
    transitive delegate target (sees through chains of wrappers).
  - `function_size(func, size)` — instruction count per function.
  - `small_function(func)` — functions with <= 12 instructions.
  """

  @behaviour Argus.Analysis

  @impl true
  def name, do: :function_summary

  @impl true
  def description, do: "function summary and delegate detection"

  @impl true
  def rules_file, do: "analyses/function_summary.dl"

  @impl true
  def extractors, do: []

  @impl true
  def output_relations do
    [
      %{
        name: :function_summary_call,
        fields: [
          {:func, :symbol, "wrapper function ID"},
          {:target_mod, :symbol, "effective target module"},
          {:target_func, :symbol, "effective target function"},
          {:target_arity, :number, "effective target arity"}
        ],
        doc: "Calling this function effectively calls the target."
      },
      %{
        name: :tail_call_delegate,
        fields: [
          {:func, :symbol, "delegate function ID"},
          {:target_mod, :symbol, "target module"},
          {:target_func, :symbol, "target function"},
          {:target_arity, :number, "target arity"}
        ],
        doc: "Delegate function whose call is in tail position."
      },
      %{
        name: :transitive_summary,
        fields: [
          {:func, :symbol, "wrapper function ID"},
          {:target_mod, :symbol, "transitive target module"},
          {:target_func, :symbol, "transitive target function"},
          {:target_arity, :number, "transitive target arity"}
        ],
        doc: "Transitive delegate target through chains of wrappers."
      },
      %{
        name: :function_size,
        fields: [
          {:func, :symbol, "function ID"},
          {:size, :number, "instruction count"}
        ],
        doc: "Number of instructions in a function."
      },
      %{
        name: :small_function,
        fields: [
          {:func, :symbol, "function ID"}
        ],
        doc: "Function with 12 or fewer instructions."
      }
    ]
  end
end
