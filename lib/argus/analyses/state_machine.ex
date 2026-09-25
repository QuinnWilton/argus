defmodule Argus.Analyses.StateMachine do
  @moduledoc """
  gen_statem graph defects.

  The state machine as a graph, scoped to `state_functions` mode where
  states are function names the extractor can read.

  - `unreachable_state(mod, state, site)` — a state no transition from
    another state (or from a helper building one) leads to, and not the
    initial state: dead code, or a missing transition.
  - `terminal_without_stop(mod, state, site)` — a state function entered
    from another state with no transition to a third and no stop. A
    state's own `keep_state` is neither a way in nor a way out.
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
  def extractors, do: [Argus.Extractors.GenStatem, Argus.Extractors.Tooling]

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
        doc: "State entered from another that no transition leaves and that doesn't stop."
      },
      Argus.Findings.Tooling.relation()
    ]
  end

  @impl true
  def finding(:unreachable_state, [mod, state, site]) do
    Findings.new(
      :warning,
      "Unreachable gen_statem state",
      "#{mod} defines state #{state}, but no transition leads to it. Either " <>
        "the state is dead code, or a transition that should produce it is " <>
        "missing — both point at a hole in the machine's design.",
      at: Findings.at_site(site, mod),
      at_label: "declared here, never entered",
      help: ["add the transition that should produce #{state}, or remove the state"]
    )
  end

  def finding(:terminal_without_stop, [mod, state, site]) do
    Findings.new(
      :info,
      "Terminal gen_statem state that never stops",
      "#{mod}'s state #{state} is entered from another state, but every " <>
        "clause keeps the machine in it and none stops it. The process " <>
        "idles in #{state} forever. If that's a " <>
        "deliberate final resting state, ignore this; otherwise it leaks a " <>
        "process per machine that reaches it.",
      at: Findings.at_site(site, mod),
      at_label: "no transition leaves #{state}",
      help: [
        "stop the machine from #{state} (`{:stop, :normal, data}`) if it is not a resting state"
      ]
    )
  end
end
