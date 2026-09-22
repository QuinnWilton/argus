defmodule Argus.Analyses.StateMachine do
  @moduledoc """
  gen_statem graph defects.

  The state machine as a graph, scoped to `state_functions` mode where
  states are function names the extractor can read.

  - `unreachable_state(mod, state, site)` — a state no transition leads
    to: dead code, or a missing transition.
  - `terminal_without_stop(mod, state, site)` — a state with no outgoing
    transitions that never stops the machine.
  """

  @behaviour Argus.Analysis

  alias Argus.Findings

  @impl true
  def name, do: :state_machine

  @impl true
  def description,
    do: "gen_statem states no transition reaches, and terminal states that never stop"

  @impl true
  def rules_file, do: "analyses/state_machine.dl"

  @impl true
  def extractors, do: [Argus.Extractors.GenStatem]

  @impl true
  def output_relations do
    [
      %{
        name: :unreachable_state,
        fields: [
          {:mod, :symbol, "module"},
          {:state, :symbol, "unreachable state"},
          {:site, :symbol, "where the state is defined or matched"}
        ],
        key: [:mod, :state],
        doc: "State defined but no transition leads to it."
      },
      %{
        name: :terminal_without_stop,
        fields: [
          {:mod, :symbol, "module"},
          {:state, :symbol, "terminal state"},
          {:site, :symbol, "where the state is defined or matched"}
        ],
        key: [:mod, :state],
        doc: "State with no outgoing transitions that doesn't stop."
      }
    ]
  end

  @impl true
  def finding(:unreachable_state, [mod, state, site]) do
    Findings.new(
      :warning,
      "Unreachable state #{state}",
      "#{mod} defines state #{state}, but no transition leads to it. Either " <>
        "the state is dead code, or a transition that should produce it is " <>
        "missing — both point at a hole in the machine's design.",
      at: Findings.at_site(site, mod)
    )
  end

  def finding(:terminal_without_stop, [mod, state, site]) do
    Findings.new(
      :info,
      "Terminal state #{state} never stops",
      "#{mod}'s state #{state} has no outgoing transitions and never stops " <>
        "the machine. The process idles in #{state} forever. If that's a " <>
        "deliberate final resting state, ignore this; otherwise it leaks a " <>
        "process per machine that reaches it.",
      at: Findings.at_site(site, mod)
    )
  end
end
