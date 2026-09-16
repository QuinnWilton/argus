defmodule Argus.Analyses.GenStatem do
  @moduledoc """
  gen_statem state machine correctness analysis.

  Detects structural state machine bugs: unreachable states and terminal
  states that never stop. Both rules reason over the extracted transition
  graph and are scoped to `state_functions` mode; in
  `handle_event_function` mode there is a single callback and states are
  data values, so a per-state graph cannot be built. A state is a state
  only if it is an exported arity-3 function that returns a gen_statem
  action, and the entry point is read from `init/1` rather than guessed
  topologically.

  ## Output relations

  - `unreachable_state(mod, state, site)` — state defined but no transition leads to it.
  - `terminal_without_stop(mod, state, site)` — state with no outgoing transitions that doesn't stop.
  - `state_missing_info_catchall(mod, state, site)` — a state function
    without an `:info` catch-all clause beside sibling states that have one.
  - `statem_timeout_unhandled(mod, kind, state)` — a `:timeout` or
    `:state_timeout` action is armed and no clause handles that event type.

  ## Finding severities

  - `unreachable_state` — `:warning`. Dead state code is either an unused
    leftover or a missing transition; both are design bugs in the machine.
  - `terminal_without_stop` — `:info`. A final resting state can be
    intentional; flagged because an unintentional one leaks an idle
    process.
  - `state_missing_info_catchall` — `:warning`. The module handles stray
    messages in its other states; in this one they are a crash.
  - `statem_timeout_unhandled` — `:error`. The timer fires into a
    FunctionClauseError or falls through to a clause written for
    something else; either way the timeout's work never runs.
  """

  @behaviour Argus.Analysis

  alias Argus.Findings

  @impl true
  def name, do: :gen_statem

  @impl true
  def description,
    do: "gen_statem correctness: unreachable states and terminal states that never stop"

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
        name: :state_missing_info_catchall,
        fields: [
          {:mod, :symbol, "module"},
          {:state, :symbol, "the state without an :info catch-all"},
          {:site, :symbol, "the state function"}
        ],
        doc: "A state function has no :info catch-all while sibling states do."
      },
      %{
        name: :statem_timeout_unhandled,
        fields: [
          {:mod, :symbol, "module"},
          {:kind, :symbol, "event_timeout or state_timeout"},
          {:state, :symbol, "the state (or handle_event) arming it"}
        ],
        key: [:mod, :kind],
        doc: "A timeout is armed and no clause handles its event type."
      },
      %{
        name: :call_never_replied,
        fields: [
          {:mod, :symbol, "module"},
          {:func, :symbol, "the state function or handle_event/4"},
          {:site, :symbol, "the return that answers nothing"}
        ],
        doc: "A {:call, from} clause returns without replying, postponing, or keeping from."
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

  def finding(:state_missing_info_catchall, [mod, state, site]) do
    Findings.new(
      :warning,
      "State #{state} has no :info catch-all",
      "#{mod}'s other states end with an `(:info, _msg, _data)` clause; " <>
        "#{state} does not. Any message that arrives while the machine is " <>
        "in #{state} and matches none of its clauses — a late :DOWN, a " <>
        "reply to a call that timed out, a library's notification — is a " <>
        "FunctionClauseError, and takes the process (and under :one_for_all, " <>
        "its whole tree) down with it.",
      at: Findings.at_site(site, mod),
      at_label: "no clause here accepts an unexpected message",
      help: ["add a final `#{state}(:info, _msg, data)` clause, as the other states have"]
    )
  end

  def finding(:statem_timeout_unhandled, [mod, kind, state]) do
    {action, type} =
      case kind do
        "state_timeout" -> {"{:state_timeout, ms, content}", ":state_timeout"}
        _ -> {"{:timeout, ms, content}", ":timeout"}
      end

    at =
      case state do
        "handle_event" -> Findings.at_mfa(mod, :handle_event, 4)
        name -> Findings.at_mfa(mod, String.to_atom(name), 3)
      end

    Findings.new(
      :error,
      "Timeout armed but never handled",
      "#{mod} arms a #{action} action in #{state}, which delivers an event " <>
        "of type #{type} — and no clause matches that event type. When the " <>
        "timer fires the event either raises FunctionClauseError or falls " <>
        "through to a clause written for something else; the work the " <>
        "timeout was meant to trigger never runs. A common shape is " <>
        "handling it as `(:info, :timeout, ...)`: the event type is " <>
        "#{type}, not :info.",
      at: at,
      at_label: "the timeout is armed here",
      help: ["add a clause matching `(#{type}, content, ...)` for the armed timeout"]
    )
  end

  def finding(:call_never_replied, [mod, func, site]) do
    Findings.new(
      :warning,
      "A {:call, from} clause never replies",
      "#{func} handles a {:call, from} event and, on the path ending here, returns " <>
        "without a {:reply, from, _} action, without postponing the event, and " <>
        "without keeping `from` for a later reply. The caller of " <>
        ":gen_statem.call/2 waits :infinity by default, so it stays blocked for " <>
        "as long as #{mod} lives.",
      at: Findings.at_site(site, mod),
      at_label: "returns here without answering the call",
      help: [
        "return `{:keep_state_and_data, [{:reply, from, value}]}` (or `:postpone` " <>
          "the event until a state that can answer)",
        "if the caller must not wait, give the call a timeout"
      ]
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
