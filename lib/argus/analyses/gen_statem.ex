defmodule Argus.Analyses.GenStatem do
  @moduledoc """
  gen_statem state machine correctness analysis.

  Detects state machine bugs: unreachable states, terminal states without
  stop, missing timeout handlers, and nondeterministic transitions.

  ## Output relations

  - `unreachable_state(mod, state)` — state defined but no transition leads to it.
  - `terminal_without_stop(mod, state)` — state with no outgoing transitions that doesn't stop.
  """

  @behaviour Argus.Analysis

  @impl true
  def name, do: :gen_statem

  @impl true
  def description,
    do: "gen_statem correctness: unreachable states, missing transitions, timeout issues"

  @impl true
  def rules_file, do: "analyses/gen_statem.dl"

  @impl true
  def extractors, do: [Argus.Extractors.GenStatem]

  @impl true
  def output_relations do
    [
      %{
        name: :unreachable_state,
        fields: [
          {:mod, :symbol, "module"},
          {:state, :symbol, "unreachable state"}
        ],
        doc: "State defined but no transition leads to it."
      },
      %{
        name: :terminal_without_stop,
        fields: [
          {:mod, :symbol, "module"},
          {:state, :symbol, "terminal state"}
        ],
        doc: "State with no outgoing transitions that doesn't stop."
      }
    ]
  end
end
