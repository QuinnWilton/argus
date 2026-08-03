defmodule Argus.Analyses.MonitorLeak do
  @moduledoc """
  A monitor whose `{:DOWN, ...}` nobody is waiting for any more.

  `Process.monitor/1` is a promise the runtime keeps: a
  `{:DOWN, ref, :process, object, reason}` **will** arrive unless cancelled.
  Waiting for it in a `receive` with an `after` clause means the wait can end
  without the message — and the monitor is still live, so it arrives later,
  into a callback that has moved on, carrying a reason that no longer means
  anything.

  `Process.demonitor(ref)` does not fix it. A `{:DOWN, ...}` already sent
  stays in the mailbox; only `Process.demonitor(ref, [:flush])` removes it.

  ## The timeout is the whole discriminator

  A `receive` with no `after` consumes either the reply or the `:DOWN` and
  cannot leak. Every monitor-plus-receive in Livebook is that shape, and none
  is reported — which is what makes the one that is reported worth reading.
  """

  @behaviour Argus.Analysis

  alias Argus.Findings

  @impl true
  def name, do: :monitor_leak

  @impl true
  def description, do: "monitors left live after a timed wait gave up"

  @impl true
  def rules_file, do: "analyses/monitor_leak.dl"

  @impl true
  def extractors, do: [Argus.Extractors.Monitor]

  @impl true
  def output_relations do
    [
      %{
        name: :leaked_monitor,
        fields: [
          {:func, :symbol, "the function establishing the monitor"},
          {:id, :symbol, "the monitor call site"}
        ],
        key: [:func],
        doc: "A monitor established before a timed wait, never flushed."
      }
    ]
  end

  @impl true
  def finding(:leaked_monitor, [func, id]) do
    Findings.new(
      :error,
      "#{func} leaves a monitor live after its wait times out",
      "#{func} calls Process.monitor/1 and then waits in a receive with an " <>
        "after clause, without Process.demonitor(ref, [:flush]). " <>
        "On the timeout branch the monitor is still live, so the " <>
        "{:DOWN, ref, :process, object, reason} arrives later — after the " <>
        "function returned, into whatever callback is running then. " <>
        "Two things usually follow. If no clause matches that message the " <>
        "process dies with a bad-event or FunctionClauseError, and it dies on " <>
        "an error path, which is when its state is most worth keeping. If a " <>
        "clause does match, it runs with a reason describing something the " <>
        "code stopped caring about. " <>
        "Note that plain Process.demonitor(ref) is not enough: a {:DOWN, ...} " <>
        "already in the mailbox stays there, and only the [:flush] option " <>
        "removes it. " <>
        "A receive with no after clause does not have this problem, since it " <>
        "consumes either the reply or the {:DOWN, ...}.",
      at: Findings.at_instr(id)
    )
  end
end
