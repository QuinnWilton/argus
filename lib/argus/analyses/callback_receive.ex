defmodule Argus.Analyses.CallbackReceive do
  @moduledoc """
  Bare `receive` inside an OTP callback.

  An OTP process is already sitting in a receive loop owned by its behaviour
  module. A `receive` written inside a callback runs *inside* that loop and
  selectively consumes from the same mailbox, which breaks three things at
  once:

  1. **It steals messages the behaviour needs.** `{:system, _, _}` is how
     `:sys.get_state/1`, `:sys.suspend/1`, `:sys.replace_state/2` and the
     whole debug and trace surface work; `{:EXIT, _, _}` is how a trapping
     process learns a link died; `{:DOWN, ...}` is every monitor in flight.
     A receive with a catch-all clause eats them.
  2. **It reorders delivery.** Messages the callback does not match stay in
     the queue and are re-scanned on every later receive — the selective
     receive cliff, quadratic in queue length.
  3. **Without an `after`, it can block forever.** The process stops
     answering its supervisor, so shutdown waits out the child's timeout and
     then brutal-kills it, turning a graceful stop into a lost buffer.

  There is no compiler or dialyzer diagnostic for this, and it survives
  review because the `receive` usually looks locally reasonable.

  ## Precision

  `call_edge` deliberately treats closure construction as a call so that
  reachability follows execution into lambdas passed to `Enum.map`,
  `Task.async` and friends. That is right in general and wrong here: a
  `receive` inside `spawn(fn -> ... end)` runs in the *spawned* process, not
  the callback's. Closure edges are subtracted, so what remains is control
  that stays on this process's stack.
  """

  @behaviour Argus.Analysis

  alias Argus.Findings

  @impl true
  def name, do: :callback_receive

  @impl true
  def description,
    do: "receive inside an OTP callback, which consumes the behaviour's own mailbox"

  @impl true
  def rules_file, do: "analyses/callback_receive.dl"

  @impl true
  def extractors, do: [Argus.Extractors.OTP]

  @fields [
    {:id, :symbol, "instruction ID of the receive"},
    {:func, :symbol, "function containing the receive"},
    {:callback, :symbol, "the OTP callback it runs under"},
    {:behaviour, :symbol, "the behaviour that owns the process loop"},
    {:proximity, :symbol, "direct (in the callback) | helper (one call away)"}
  ]

  @impl true
  def output_relations do
    [
      %{
        name: :blocking_receive_in_callback,
        fields: @fields,
        key: [:id],
        doc: "A receive with no timeout, running on an OTP process's own stack."
      },
      %{
        name: :receive_in_callback,
        fields: @fields,
        key: [:id],
        doc: "A receive with a timeout, still consuming the behaviour's mailbox."
      }
    ]
  end

  @impl true
  def finding(:blocking_receive_in_callback, [id, func, callback, behaviour, proximity]) do
    Findings.new(
      :error,
      "Blocking receive inside a #{behaviour} callback",
      "#{func} runs a `receive` with no `after`, #{where(proximity, callback)}. It " <>
        "executes on the #{behaviour} process's own stack, so it consumes from " <>
        "the mailbox the behaviour is managing: {:system, _, _} (which is how " <>
        ":sys.get_state and the debug surface reach the process), {:EXIT, _, _} " <>
        "when trapping, and every in-flight monitor's {:DOWN, ...}. With no " <>
        "timeout it can also block forever — the supervisor's shutdown then " <>
        "waits out the child timeout and brutal-kills, losing whatever the " <>
        "process was holding. Move the wait into a task and reply to the " <>
        "callback with a message, or handle the reply in handle_info.",
      at: Findings.at_instr(id)
    )
  end

  def finding(:receive_in_callback, [id, func, callback, behaviour, proximity]) do
    Findings.new(
      :warning,
      "receive inside a #{behaviour} callback",
      "#{func} runs a `receive`, #{where(proximity, callback)}. It has a " <>
        "timeout so it cannot hang, but it still executes on the #{behaviour} " <>
        "process's own stack and selectively consumes from the mailbox the " <>
        "behaviour manages — including the system messages :sys and the " <>
        "supervisor rely on. Messages it does not match are left in the queue " <>
        "and re-scanned by every later receive.",
      at: Findings.at_instr(id)
    )
  end

  defp where("direct", callback), do: "and #{callback} is that callback"
  defp where(_helper, callback), do: "reached directly from the callback #{callback}"
end
