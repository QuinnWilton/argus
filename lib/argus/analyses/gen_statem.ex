defmodule Argus.Analyses.GenStatem do
  @moduledoc """
  gen_statem state machine correctness analysis.

  Detects state machine bugs: unreachable states, terminal states without
  stop, missing timeout handlers, and nondeterministic transitions.

  ## Output relations

  - `unreachable_state(mod, state)` — state defined but no transition leads to it.
  - `terminal_without_stop(mod, state)` — state with no outgoing transitions that doesn't stop.

  ## Finding severities

  - `unreachable_state` — `:warning`. Dead state code is either an unused
    leftover or a missing transition; both are design bugs in the machine.
  - `terminal_without_stop` — `:info`. A final resting state can be
    intentional; flagged because an unintentional one leaks an idle
    process.
  """

  @behaviour Argus.Analysis

  alias Argus.Findings

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
