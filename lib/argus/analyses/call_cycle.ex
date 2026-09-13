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

  ## Finding severities

  - `call_cycle` — `:error`. A mutual synchronous dependency deadlocks the
    moment both directions are in flight; timeouts only convert the
    deadlock into cascading crashes.
  - `call_cycle_path` — `:info`. Supporting evidence: the individual edges
    behind a `call_cycle` finding.
  """

  @behaviour Argus.Analysis

  alias Argus.Findings

  @impl true
  def name, do: :call_cycle

  @impl true
  def description, do: "module-level synchronous call cycle (deadlock) detection"

  @impl true
  def rules_file, do: "analyses/call_cycle.dl"

  @impl true
  def extractors,
    do: [
      Argus.Extractors.OTP,
      Argus.Extractors.ApiCalls,
      Argus.Extractors.CallbackTag,
      # call_cycle's rules join call_arg and call_arg_forward through
      # clientlib/interprocedural.dl to follow a pid or name through a
      # function argument. Nothing declared CallArgs, so those relations were
      # empty and the forwarding layer derived nothing.
      Argus.Extractors.CallArgs
    ]

  @impl true
  def output_relations do
    [
      %{
        name: :call_cycle,
        fields: [
          {:mod_a, :symbol, "first module in cycle"},
          {:mod_b, :symbol, "second module in cycle"},
          {:witness_a, :symbol, "function in mod_a carrying the a→b dependency"},
          {:witness_b, :symbol, "function in mod_b carrying the b→a return path"}
        ],
        key: [:mod_a, :mod_b],
        doc: "Pair of modules with mutual synchronous dependency."
      },
      %{
        name: :call_cycle_path,
        fields: [
          {:from_mod, :symbol, "source module"},
          {:to_mod, :symbol, "target module"},
          {:witness, :symbol, "function in from_mod carrying the dependency"}
        ],
        key: [:from_mod, :to_mod],
        doc: "Transitive sync dependency edge between cycle participants."
      }
    ]
  end

  @impl true
  def finding(:call_cycle, [mod_a, mod_b, witness_a, witness_b]) do
    Findings.new(
      :error,
      "Synchronous call cycle",
      "#{mod_a} and #{mod_b} synchronously call each other, directly or through " <>
        "intermediaries. If both directions are ever in flight at once, each " <>
        "process blocks waiting on the other's mailbox — a deadlock that " <>
        "GenServer.call timeouts only turn into cascading crashes. Break one " <>
        "direction with a cast or a message.",
      at: Findings.at_func(witness_a),
      related: [Findings.related("return path", Findings.at_func(witness_b))]
    )
  end

  def finding(:call_cycle_path, [from_mod, to_mod, witness]) do
    Findings.new(
      :info,
      "Cycle edge: #{from_mod} → #{to_mod}",
      "Synchronous dependency edge between call-cycle participants — the " <>
        "evidence behind a call_cycle finding.",
      at: Findings.at_func(witness),
      related: [Findings.related("callee", Findings.at_module(to_mod))]
    )
  end
end
