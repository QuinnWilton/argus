defmodule Argus.Analyses.CallCycle do
  @moduledoc """
  Call cycle (deadlock) detection.

  Finds module-level synchronous dependency cycles: module A sync-calls B
  and B sync-calls A, either directly or transitively through the call graph.
  A cycle between two GenServer modules means each can block waiting for the
  other, producing a deadlock.

  Requires the OTP extractor for `sync_call` and `implements_behaviour` facts.

  ## Output relations

  - `call_cycle(mod_a, mod_b)` — pair of modules with mutual synchronous dependency.
  - `call_cycle_path(from_mod, to_mod)` — transitive sync dependency edges within cycle participants.
  """

  @behaviour Argus.Analysis

  @impl true
  def name, do: :call_cycle

  @impl true
  def description, do: "module-level synchronous call cycle (deadlock) detection"

  @impl true
  def rules_file, do: "analyses/call_cycle.dl"

  @impl true
  def extractors, do: [Argus.Extractors.OTP, Argus.Extractors.GenEvent]

  @impl true
  def output_relations do
    [
      %{
        name: :call_cycle,
        fields: [
          {:mod_a, :symbol, "first module in cycle"},
          {:mod_b, :symbol, "second module in cycle"}
        ],
        doc: "Pair of modules with mutual synchronous dependency."
      },
      %{
        name: :call_cycle_path,
        fields: [
          {:from_mod, :symbol, "source module"},
          {:to_mod, :symbol, "target module"}
        ],
        doc: "Transitive sync dependency edge between cycle participants."
      }
    ]
  end
end
