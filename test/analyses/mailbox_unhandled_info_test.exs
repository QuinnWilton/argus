defmodule Argus.Analyses.MailboxUnhandledInfoTest do
  use ExUnit.Case, async: true
  @moduletag :flowlog

  alias Argus.Analyses.Mailbox
  alias Argus.Test.{Batch, Memo}
  alias Argus.Test.Fixtures, as: F
  alias Argus.Test.Fixtures.Hypothesized, as: H
  alias Argus.Test.Fixtures.LateMessage, as: L
  alias Argus.Test.Fixtures.UnhandledInfo, as: U

  @all [
    U.MemoryCheck,
    U.Reconnect,
    U.Listeners,
    U.Repair,
    U.Ticker,
    U.Pinger,
    U.PingServer,
    U.EnvelopeCaster,
    U.EnvelopeServer,
    U.Handled,
    U.Delegates,
    U.OpenClause,
    U.WaitsForDown,
    U.Flushes,
    U.Client,
    U.Poller,
    U.PollerTakes,
    U.Retry,
    U.WarmUp,
    U.Unjudged,
    U.TerminateWaits,
    U.TaskReceives,
    U.TickArity,
    U.MixedCatchAll
  ]

  # The retired catch-all rule's probes (below), with the messages each
  # is shown to be sent that fall through its clauses.
  @probes [
    # The runtime source: what it writes a server that monitors or traps.
    # The ref pinned to the state, a state field compared: the program's.
    {[F.MonitorsWithoutCatchall], []},
    {[F.MonitorsDownWhenActive], []},
    {[L.MonitorsInMacro, L.MonitorMacro], []},
    # No link: the one :EXIT a GenServer gets, its parent's, it takes itself.
    {[F.TrapsTakingNormalExits], []},
    {[F.MonitorsPortTakingProcessDowns], [{"{:DOWN, …}", "monitor"}]},
    {[F.MonitorsDownGuardedByReason], [{"{:DOWN, …}", "monitor"}]},
    {[F.MonitorsNodesTakingDowns], [{"{:nodedown, …}", "node"}, {"{:nodeup, …}", "node"}]},
    {[F.TrapsOpeningPort], [{"{port, {:data, …}}", "port"}]},
    # The late-message source: a timer, a task, a self-send, a fun.
    {[F.PartialInfoStage], [{":tick", "timer"}]},
    {[L.StartTimerIdle], [{"{:timeout, …}", "timer"}]},
    # A timer whose message the state holds shows no message.
    {[F.PartialInfoServer], []},
    {[F.InlineOrTaskPartialInfoServer], []},
    # A self-sent :warm, a warmer's {:warm, nil}: each has its clause.
    {[F.SelfSendPartialInfoServer], []},
    {[L.Warmer, L.WarmerMacro], []},
    # Code the server runs that it did not build shows no message.
    {[F.AppliesPartialInfoServer], []},
    {[L.RunsSentFun], []},
    {[L.CallsInClosure], []},
    {[L.HandsMixed], []},
    # The task_nolink source, folded: a task's reply and :DOWN.
    {[H.NolinkPartialInfo], [{"{:DOWN, …}", "task"}, {"{ref, …}", "task"}]},
    {[L.NolinkInMacro, L.NolinkMacro], [{"{:DOWN, …}", "task"}]},
    # The statem_info source: a state without the :info catch-all its
    # siblings have, and no message shown to reach it.
    {[F.AsymmetricInfoStatem], []},
    # Its quiet neighbours stay quiet: every :DOWN and :EXIT taken, a
    # timer's tag taken, a timer a task arms, a monitor a client
    # function takes in its caller, nothing that writes the mailbox, a
    # closure the server builds, the logger's handlers, a machine whose
    # every state has the catch-all.
    {[F.TrapsTakingEveryExit], []},
    {[F.TaggedTimerServer], []},
    {[F.HandledTimerServer], []},
    {[F.TaskTimerPartialInfoServer], []},
    {[F.ClientMonitorsServer], []},
    {[F.TotalInfoServer], []},
    {[F.QuietPartialInfoServer], []},
    {[L.HandsClosure], []},
    {[L.LogsOnTick], []},
    {[F.SymmetricInfoStatem], []}
  ]

  setup_all do
    probes = Batch.solve(:mailbox, Enum.map(@probes, &elem(&1, 0)))
    {:ok, results} = Memo.analyze(@all, :mailbox)
    short = &String.replace(&1, "Argus.Test.Fixtures.UnhandledInfo.", "")

    rows =
      for [_mod, func, _site, message, source, server, _handler, fallback] <-
            results["unhandled_info"],
          do: {short.(func), message, source, short.(server), fallback}

    %{rows: rows, results: results, probes: probes}
  end

  test "every message a server is shown to be sent and no clause takes, exactly", %{rows: rows} do
    assert Enum.sort(rows) ==
             Enum.sort([
               # A timer the server arms for itself, with no clause for it.
               {"MemoryCheck:schedule_memory_check/0", ":memory_check", "timer", "MemoryCheck",
                "crash"},
               {"Reconnect:schedule_connect/0", ":connect", "timer", "Reconnect", "crash"},
               # A gen envelope sent by hand is a call or a cast, not a
               # message: only the plain send is one.
               {"EnvelopeCaster:run/0", "{:refresh_now, …}", "send", "EnvelopeServer", "crash"},
               # A monitor's :DOWN a catch-all drops.
               {"Listeners:handle_call/3", "{:DOWN, …}", "monitor", "Listeners", "catch_all"},
               # A timer message a logging catch-all takes, and one
               # GenServer's default takes.
               {"Repair:init/1", ":repair", "timer", "Repair", "catch_all"},
               {"Ticker:init/1", ":tick", "send", "Ticker", "default"},
               # A catch-all after a clause a `use` put first is the
               # module's own.
               {"MixedCatchAll:init/1", ":stray", "timer", "MixedCatchAll", "catch_all"},
               # A send points-to follows to another module's server.
               {"Pinger:run/0", ":ping", "send", "PingServer", "crash"},
               # A gen_statem no state of which takes a message it is sent.
               {"Poller:init/1", ":poll", "timer", "Poller", "state_crash"},
               # A literal tuple, and one the site builds, told apart by
               # their tag.
               {"Retry:init/1", "{:retry, 3}", "timer", "Retry", "crash"},
               {"Retry:handle_info/2", "{:backoff, …}", "timer", "Retry", "crash"},
               # A receive in a closure a Task runs is the Task's, not the
               # server's.
               {"TaskReceives:init/1", ":tick", "timer", "TaskReceives", "crash"},
               # A timer whose tag a clause takes in another shape is not
               # taken; {:tock, :fast}, in the shape the clause takes, is.
               {"TickArity:init/1", "{:tick, 1, :slow}", "timer", "TickArity", "crash"},
               {"TickArity:init/1", "{:tick, …}", "timer", "TickArity", "crash"}
             ])

    # Quiet: Handled, Delegates, OpenClause, WaitsForDown, Flushes,
    # Client, PollerTakes, WarmUp, Unjudged, TerminateWaits.
  end

  test "a monitor's :DOWN is taken by a clause for every reason, whatever it asks of the ref" do
    alias Argus.Test.Soundness.Witness, as: W

    # Clauses that split the reasons, a reason decided in the body, a port
    # clause that leaves the type alone; a pinned ref and a compared state
    # field are the program's choice of which monitors it keeps.
    quiet = [
      W.DownSplitReasons,
      W.DownReasonInBody,
      W.PortDownAnyType,
      F.MonitorsTakingEveryDown,
      F.MonitorsWithoutCatchall,
      F.MonitorsDownWhenActive
    ]

    {:ok, results} = Memo.analyze(quiet, :mailbox)
    assert results["unhandled_info"] == []
  end

  test "a wait with no after, a late reply taken, a task's messages taken, node events taken" do
    alias Argus.Test.Soundness.Witness, as: W

    quiet = [
      W.ExitEveryReason,
      W.ExitNoLink,
      W.ExitNoClause,
      W.PmapServer,
      W.Pmap,
      W.SpawnBlockingWait,
      W.LateReplyTaken,
      W.LateCatchAll,
      W.SpawnPoll,
      L.TimedCall,
      W.NolinkTupleClause,
      Argus.Test.Fixtures.Hypothesized.NolinkBothClauses,
      Argus.Test.Fixtures.Hypothesized.NolinkCollected,
      W.NodesTaken,
      W.NodesOff,
      W.PortReadThere,
      W.PortDataTaken,
      W.StartTimerElsewhere,
      L.StartTimer
    ]

    {:ok, results} = Memo.analyze(quiet, :mailbox)
    assert results["unhandled_info"] == []
  end

  describe "the retired catch-all rule's probes" do
    # "handle_info/2 has no catch-all" (partial_handler, retired) reported
    # each of these for the catch-all it lacks. A missing catch-all is no
    # finding by itself: a message the program is shown to send that falls
    # through it is, and a probe that shows none is quiet. The probes
    # (`@probes`, above) are solved together, one batch.

    test "each shows only the messages it is shown to be sent that fall through",
         %{probes: probes} do
      assert {:ok, all} = probes.result
      refute Map.has_key?(all, "partial_handler")

      wrong =
        for {modules, expected} <- @probes,
            {:ok, results} = Batch.analyze(probes, modules),
            found =
              Enum.sort(
                for [_, _, _, message, source | _] <- results["unhandled_info"],
                    do: {message, source}
              ),
            found != expected,
            do: {modules, found: found, expected: expected}

      assert wrong == []
    end
  end

  describe "finding" do
    test "names the message, where it comes from and what takes it instead" do
      crash =
        Mailbox.finding(:unhandled_info, [
          "Mod",
          "Mod:schedule/0",
          "Mod:schedule/0#3",
          ":tick",
          "timer",
          "Mod",
          "Mod:handle_info/2",
          "crash"
        ])

      # A timer the program arms crashes the server with nothing else
      # needed: :error, as a call with a tag the server cannot take is.
      assert crash.severity == :error
      assert crash.title == "No handle_info/2 clause for a message the server is sent"

      down_crash =
        Mailbox.finding(:unhandled_info, [
          "Mod",
          "Mod:handle_call/3",
          "Mod:handle_call/3#5",
          "{:DOWN, …}",
          "monitor",
          "Mod",
          "Mod:handle_info/2",
          "crash"
        ])

      # A monitor's :DOWN comes only when the monitored process exits.
      assert down_crash.severity == :warning
      assert crash.detail =~ ":tick"
      assert crash.detail =~ "FunctionClauseError"

      down =
        Mailbox.finding(:unhandled_info, [
          "Mod",
          "Mod:handle_call/3",
          "Mod:handle_call/3#5",
          "{:DOWN, …}",
          "monitor",
          "Mod",
          "Mod:handle_info/2",
          "catch_all"
        ])

      assert down.severity == :warning
      assert down.title =~ "catch-all"
      assert Enum.any?(down.help, &(&1 =~ ":DOWN"))

      sent =
        Mailbox.finding(:unhandled_info, [
          "Mod",
          "Mod:init/1",
          "Mod:init/1#2",
          ":repair",
          "timer",
          "Mod",
          "Mod:handle_info/2",
          "catch_all"
        ])

      assert sent.severity == :info

      state =
        Mailbox.finding(:unhandled_info, [
          "Mod",
          "Mod:init/1",
          "Mod:init/1#2",
          ":poll",
          "timer",
          "Mod",
          "Mod:idle/3",
          "state_crash"
        ])

      assert state.title == "No clause for a message a gen_statem is sent"
      assert state.detail =~ ":info"
    end
  end
end
