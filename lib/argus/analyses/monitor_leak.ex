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
  The wait may sit a call below the monitor, in the same module and
  process; closure edges do not count.

  ## Monitors over a server's lifetime

  Two further shapes are about the process rather than one function, and
  are reported at `:info` because they are heuristics over a module's
  callbacks rather than proofs about one path:

  - `monitor_never_released` — a callback-loop module monitors from its
    callbacks, removes entries from its bookkeeping somewhere, and calls
    `Process.demonitor` nowhere. Postgrex's `Parameters` server.
  - `monitor_ref_discarded` — a callback calls `Process.monitor/1` and
    drops the ref, so the monitor can only end with the monitored
    process. Phoenix PubSub's Local, for every subscriber.
  - `deliberate_termination_while_monitored` — the module terminates a
    child or stops a server it monitors, without demonitoring first, so
    the `{:DOWN, ...}` for a death it caused arrives in the clause written
    for crashes. Oban's producer on pkill; Redix's cluster manager on a
    departed node.
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
  def extractors,
    do: [
      Argus.Extractors.Monitor,
      Argus.Extractors.OTP,
      Argus.Extractors.ApiCalls,
      Argus.Extractors.GenStatem
    ]

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
      },
      %{
        name: :monitor_never_released,
        fields: [
          {:mod, :symbol, "the server module"},
          {:site, :symbol, "a monitor call site in its callbacks"}
        ],
        key: [:mod],
        doc:
          "A server monitors from its callbacks and removes bookkeeping entries, " <>
            "but never calls Process.demonitor."
      },
      %{
        name: :monitor_ref_discarded,
        fields: [
          {:mod, :symbol, "the server module"},
          {:site, :symbol, "the monitor call whose ref is dropped"}
        ],
        doc:
          "A server callback discards the ref Process.monitor/1 returned; nothing can demonitor it."
      },
      %{
        name: :deliberate_termination_while_monitored,
        fields: [
          {:mod, :symbol, "the server module"},
          {:site, :symbol, "a monitor call site in its callbacks"},
          {:kill_site, :symbol, "the terminate_child or GenServer.stop call"}
        ],
        key: [:mod, :kill_site],
        doc: "A server terminates a process it monitors without demonitoring first."
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

  def finding(:monitor_never_released, [mod, site]) do
    Findings.new(
      :info,
      "#{mod} monitors but never demonitors",
      "#{mod} establishes monitors from its callbacks and removes entries " <>
        "from its bookkeeping elsewhere, but calls Process.demonitor nowhere. " <>
        "If an entry can leave by a path other than the monitored process " <>
        "dying — an explicit delete, unsubscribe or disconnect — its monitor " <>
        "stays live: one per cycle, for the life of the server, each one a " <>
        "future {:DOWN, ...} that arrives after the entry is gone.",
      at: Findings.at_site(site, mod),
      at_label: "monitors established here are only ever released by :DOWN",
      help: [
        "on every path that removes the entry, call " <>
          "`Process.demonitor(ref, [:flush])` with the ref stored alongside it"
      ]
    )
  end

  def finding(:monitor_ref_discarded, [mod, site]) do
    Findings.new(
      :info,
      "#{mod} drops the ref of a monitor it establishes",
      "#{mod} calls Process.monitor/1 in a callback and discards the " <>
        "result. The ref is the only handle a demonitor needs, so this " <>
        "monitor ends when the monitored process dies and not before. If " <>
        "the relationship it stands for can end another way — an " <>
        "unsubscribe, a checkin, a disconnect — the monitor outlives it, " <>
        "one per cycle, and the {:DOWN, ...} arrives for a process the " <>
        "server stopped caring about.",
      at: Findings.at_site(site, mod),
      at_label: "the monitor ref is dropped here",
      help: [
        "keep the ref with the entry it protects and " <>
          "`Process.demonitor(ref, [:flush])` when the entry is removed"
      ]
    )
  end

  def finding(:deliberate_termination_while_monitored, [mod, site, kill_site]) do
    Findings.new(
      :info,
      "#{mod} terminates a process it still monitors",
      "#{mod} monitors processes from its callbacks and also terminates " <>
        "them on purpose, without demonitoring first. The {:DOWN, ...} for a " <>
        "death this server caused is delivered like any other — into the " <>
        "clause written for crashes, which may restart, reconnect or log " <>
        "what was a deliberate stop.",
      at: Findings.at_site(kill_site, mod),
      at_label: "the monitored process is terminated here",
      help: [
        "call `Process.demonitor(ref, [:flush])` before terminating, and drop " <>
          "the entry from the bookkeeping in the same step"
      ],
      related: [Findings.related("monitor established", Findings.at_site(site, mod))]
    )
  end
end
