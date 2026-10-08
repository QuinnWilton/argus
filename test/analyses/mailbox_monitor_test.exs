defmodule Argus.Analyses.MailboxMonitorTest do
  @moduledoc """
  `monitor_leak`: a monitor that code which runs again takes again before the one before
  it is released (docs/analyses/mailbox.md#repeated-live-monitors): the run repeats, the
  process is one it can meet again, the run does not release it, and one of the three
  witnesses shows the monitor before is still live. Two solves of fixtures that do not
  meet are listed exactly, every function reported and why, every quiet neighbour and
  why; the tests after them solve what must be read together.
  """
  use ExUnit.Case, async: true
  @moduletag :flowlog

  alias Argus.Test.Fixtures.MonitorLeak, as: M
  alias Argus.Test.Memo
  alias Argus.Test.Rows

  @all [
    M.Leaks,
    M.Flushes,
    M.Blocks,
    M.NoMonitor,
    M.LeaksThroughHelper,
    M.FlushesInHelper,
    M.InEach,
    M.MapsThenDrains,
    M.ForThenForeach,
    M.MapsThenDemonitors,
    M.MapsThenGivesUp,
    M.MapsThenFindsOne,
    M.TaskGivesUp,
    M.SpawnsWatcher,
    M.TaskPolls,
    M.CollectedByCaller,
    M.ReturnsLive,
    M.WaitsOnOnePath,
    M.CollectedOnOneCaller,
    M.CollectedByRef,
    M.FlushedByCaller,
    M.WaitsForAnotherRef,
    M.GraceThenKill,
    M.StopsCursor
  ]

  @servers [
    M.NeverReleases,
    M.ReleasesOnDelete,
    M.KillsMonitored,
    M.ClientSideMonitor,
    M.DropsRef,
    M.MapsRefs,
    M.EachDropsRefs,
    M.ForeachDropsRefs,
    M.FilterDropsRefs,
    M.HelperKeepsRef,
    M.HelperDropsRef,
    M.DrainsOnTerminate,
    M.DrainsOnCall,
    M.ForkShutdown,
    M.ForkShutdownForgets,
    M.MonitorsOwnWorker,
    M.MonitorsHandedWorker
  ]

  # Every test reads one of two solves: solved once each, read-only.
  setup_all do
    %{all: Memo.analyze(@all, :mailbox), servers: Memo.analyze(@servers, :mailbox)}
  end

  # The monitoring functions reported with `how`, sorted.
  defp funcs(solved, how) do
    assert {:ok, r} = solved

    r
    |> Rows.where(:mailbox, "monitor_leak", how: how)
    |> Enum.map(&Enum.at(&1, 1))
    |> Enum.sort()
  end

  defp mods(funcs), do: Enum.sort(for f <- funcs, do: "Argus.Test.Fixtures.MonitorLeak." <> f)

  # Every monitoring function each solve reports, by how it leaks: a
  # case newly reported fails as surely as one lost.
  describe "what each solve reports, exactly" do
    test "the waits and the callers", ctx do
      assert funcs(ctx.all, "wait") ==
               mods([
                 # A timed wait with no demonitor, in a function callers
                 # call again.
                 "Leaks:wait/1",
                 # The answer path of a wait with no `after`: on the reply
                 # the monitor stays live, and the next call monitors the
                 # same process again.
                 "Blocks:wait/1",
                 # A wait one call below the monitor (Finch's HTTP/2 pool:
                 # monitor in request/1, the `after` in a private loop);
                 # the function reported is the one that monitors.
                 "LeaksThroughHelper:request/1",
                 # A wait in a closure the caller runs.
                 "InEach:-wait_all/1-fun-0-/1",
                 # A closure that may give up on one, or a call that stops
                 # early, releases none of the refs a map handed back.
                 "MapsThenGivesUp:-drain/1-fun-0-/1",
                 "MapsThenFindsOne:-first_down/1-fun-0-/1",
                 # The supervisor shutdown shape when its caller never
                 # waits.
                 "ReturnsLive:monitor_child/1"
               ])

      assert funcs(ctx.all, "dropped") ==
               mods([
                 # A task that monitors in its receive loop takes it again
                 # each round.
                 "TaskPolls:poll/1",
                 # A wait on only some paths after the call, and one caller
                 # that waits covering not another that does not.
                 "WaitsOnOnePath:monitor_child/1",
                 "CollectedOnOneCaller:monitor_child/1",
                 # monitor_and_signal/1 answers its ref; stop/2 throws it
                 # away and waits for another monitor's :DOWN.
                 "WaitsForAnotherRef:monitor_and_signal/1"
               ])

      assert funcs(ctx.all, "ended") == []

      # Released, and quiet:
      #   * Flushes: a demonitor with :flush on every way out.
      #     FlushesInHelper: a helper handed the ref does so on every way.
      #   * NoMonitor: a timed wait with no monitor has nothing to leak.
      #   * MapsThenDrains, ForThenForeach, MapsThenDemonitors: the refs an
      #     Enum.map closure hands back are the caller's, released when a
      #     closure run on every one releases its element.
      #   * GraceThenKill: a kill after the grace period, then a wait for
      #     the :DOWN. StopsCursor: a look with `after 0`, then a wait for
      #     the :DOWN on every path.
      #   * TaskGivesUp: a monitor a task takes on its way out ends with
      #     the task. SpawnsWatcher: the spawned closure is the watcher's
      #     only run, its builder hands it off (InEach's closure, run in
      #     the caller, still leaks).
      #   * CollectedByCaller: GenStage's ConsumerSupervisor and Horde's
      #     ProcessesSupervisor; monitor_child/1 looks once with `after 0`
      #     and returns with the monitor live, and terminate_children then
      #     waits for every :DOWN.
      #   * CollectedByRef, FlushedByCaller: a caller waiting on, or
      #     demonitoring, the ref it was handed.
    end

    test "the servers", ctx do
      assert funcs(ctx.servers, "wait") ==
               mods([
                 # ClientSideMonitor.request/2 runs in its caller: the reply
                 # path leaves the caller one more monitor on the server
                 # per call.
                 "ClientSideMonitor:request/2",
                 # The same drain as DrainsOnTerminate's, reached from
                 # handle_call/3 as well: what only terminate runs ends
                 # with the process.
                 "DrainsOnCall:-drain/1-fun-0-/1",
                 # A supervisor fork's monitor_child, released only where
                 # its caller waits (ForkShutdown's is).
                 "ForkShutdownForgets:monitor_child/1"
               ])

      # Monitoring on insert and deleting without demonitor.
      assert funcs(ctx.servers, "ended") == mods(["NeverReleases:handle_call/3"])

      assert funcs(ctx.servers, "dropped") ==
               mods([
                 "DropsRef:handle_call/3",
                 # A ref a tail call returns is judged by what the caller
                 # does with it: a closure handed to Enum.each or a library
                 # call that drops what its fun answers (TermFlow.Library),
                 # and a helper whose caller throws the ref away, lose it
                 # as surely as a bare monitor does.
                 "EachDropsRefs:-handle_call/3-fun-0-/1",
                 "FilterDropsRefs:-handle_call/3-fun-0-/1",
                 "ForeachDropsRefs:-handle_call/3-fun-0-/1",
                 "ForkShutdownForgets:monitor_child/1",
                 "HelperDropsRef:watch/1"
               ])

      # Quiet:
      #   * ReleasesOnDelete, KillsMonitored: a delete that demonitors,
      #     and a pop no removal names.
      #   * MapsRefs, HelperKeepsRef: the refs mapped into a set, or kept
      #     in the state.
      #   * DrainsOnTerminate: what only terminate runs ends with the
      #     process.
      #   * MonitorsOwnWorker, MonitorsHandedWorker: a worker the run
      #     itself started is new each time; whoever else the pid is
      #     handed to, this monitor is the only one the server holds on
      #     it, and its :DOWN ends both.
    end

    test "a monitor whose ref is thrown away is reported at its site", ctx do
      assert {:ok, r} = ctx.servers

      rows = Rows.where(r, :mailbox, "monitor_leak", how: "dropped", drop: [:func, :how])

      assert [site] =
               for(
                 [mod, site] <- rows,
                 mod == "Argus.Test.Fixtures.MonitorLeak.DropsRef",
                 do: site
               )

      assert site =~ "DropsRef:handle_call/3#"
    end
  end

  describe "beside the program's other code" do
    test "a wait in the logger's machinery is not the monitoring function's" do
      # With OTP's logger and gen in the program, :logger.error/1 reaches
      # gen's receive through a handler's removal: a side path
      # (side_call), whose waits are on the logger's own monitors.
      assert {:ok, r} =
               Memo.analyze(
                 [
                   M.LogsAfterMonitor,
                   M.LogsAndLeaks,
                   :logger,
                   :logger_backend,
                   :logger_server,
                   :gen_server,
                   :gen
                 ],
                 :mailbox
               )

      leaks = r |> Rows.where(:mailbox, "monitor_leak", []) |> Enum.map(&Enum.at(&1, 1))

      assert "Argus.Test.Fixtures.MonitorLeak.LogsAndLeaks:watch/1" in leaks
      refute "Argus.Test.Fixtures.MonitorLeak.LogsAfterMonitor:watch/1" in leaks
    end

    test "a worker a start answered through the program's wrappers is new each time" do
      # Issue #3: Tortoise's connection starts its transmitter through
      # another module's default-argument wrapper; a private wrapper, a
      # case that passes {:ok, pid} on, two layers and a bare pid are the
      # same start's answer (clientlib/answers.dl).
      wrapped = [
        M.Transmitters,
        M.Transmitter,
        M.ConnectsThroughWrapper,
        M.StartsThroughLocalWrapper,
        M.Starters,
        M.StartsThroughLayers
      ]

      assert {:ok, r} = Memo.analyze(wrapped, :mailbox)
      assert Map.get(r, "monitor_leak", []) == []
    end
  end

  describe "the record is where the monitor's ref or pid is kept" do
    for mod <- [
          M.ResetsAnotherField,
          M.RemovesFromAnotherField,
          M.OwnerBesideBuffers,
          M.KeepsMonitorsResetsNotifies,
          M.WritesAnotherTable,
          M.KeepsAnotherPieceOfTheMessage,
          M.FoldKeepsNodesAndChecks
        ] do
      test "#{inspect(mod)}: a drop of another field or table is no drop of the record" do
        # hackney's connection and ra's server (the monitor follow-up to
        # issue #3): a field the monitoring clause sets beside its record
        # is not the record.
        modules = [unquote(mod), M.Monitors]
        assert {:ok, r} = Memo.analyze(modules, :mailbox)
        refute Enum.any?(Map.get(r, "monitor_leak", []), &match?([_, _, _, "ended"], &1))
      end
    end
  end

  describe "what lets the monitor be taken again" do
    for mods <- [
          [M.AsksWatched],
          [M.AsksItsTable],
          [:mon_asks_pool],
          [M.PendingRefBesideListeners],
          [M.PidSlotBesideRef],
          [M.ResetsOnItsDown]
        ] do
      test "#{inspect(mods)}: no drop of the store asked, and no reset that forgets the ref" do
        # hackney_pool's register_h2 asks `pid_monitors` before it
        # monitors, and a checkout drops the pid from `h2_connections`;
        # Postgrex.Notifications resets its pending `ref` with the
        # listener's ref kept in `listeners`; hackney's connection resets
        # `stream_to` with the ref kept in `owner_mon`.
        assert {:ok, r} = Memo.analyze(unquote(mods), :mailbox)
        refute Enum.any?(Map.get(r, "monitor_leak", []), &match?([_, _, _, "ended"], &1))
      end
    end
  end

  describe "a gen_statem's clauses, by the event's type and content" do
    test "what one :internal clause records is not what another resets" do
      # Issue #3's second half: keyed by the event type alone, the pending
      # map another :internal clause resets was the receiver's record.
      assert {:ok, r} = Memo.analyze([M.StatemReceiverFromOpts], :mailbox)
      assert Map.get(r, "monitor_leak", []) == []
    end

    test "an :info clause whose content is :DOWN is the monitor's own end" do
      assert {:ok, r} = Memo.analyze([M.StatemForgetsOnDown], :mailbox)
      assert Map.get(r, "monitor_leak", []) == []
    end
  end
end
