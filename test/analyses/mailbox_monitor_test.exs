defmodule Argus.Analyses.MailboxMonitorTest do
  @moduledoc """
  `monitor_leak`: a monitor that code which runs again takes again before the one before
  it is released (docs/analyses/mailbox.md#repeated-live-monitors). Each describe block
  is one part of the model: the run repeats, the process is one it can meet again, the
  run does not release it, and one of the three witnesses shows the monitor before is
  still live.
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

  defp reported(solved) do
    Enum.flat_map(~w(wait ended dropped), &funcs(solved, &1))
  end

  defp named?(list, f), do: Enum.any?(list, &String.contains?(&1, f))

  describe "wait: the run waits on the process, and a way out keeps the monitor" do
    test "a timed wait with no demonitor, in a function callers call again", ctx do
      assert named?(funcs(ctx.all, "wait"), "MonitorLeak.Leaks:wait/1")
    end

    test "the answer path of a wait with no `after` keeps it too", ctx do
      # Blocks takes the :DOWN or the reply; on the reply the monitor stays
      # live, and the next call monitors the same process again.
      assert named?(funcs(ctx.all, "wait"), "MonitorLeak.Blocks:wait/1")
    end

    test "a demonitor with :flush on every way out releases it", ctx do
      refute named?(reported(ctx.all), "MonitorLeak.Flushes")
    end

    test "a timed wait with no monitor has nothing to leak", ctx do
      refute named?(reported(ctx.all), "MonitorLeak.NoMonitor")
    end

    test "a wait one call below the monitor", ctx do
      # Finch's HTTP/2 pool shape: monitor in request/1, the `after` in a
      # private loop. The function reported is the one that monitors.
      assert named?(funcs(ctx.all, "wait"), "MonitorLeak.LeaksThroughHelper:request/1")
    end

    test "a helper handed the ref that releases it on every way out releases it", ctx do
      refute named?(reported(ctx.all), "MonitorLeak.FlushesInHelper")
    end

    test "a wait in a closure the caller runs", ctx do
      assert named?(funcs(ctx.all, "wait"), "MonitorLeak.InEach:-wait_all/1-fun-0-")
    end

    # The refs an Enum.map closure hands back are the caller's: released
    # when a closure run on every one of them releases its element.
    test "monitors a closure hands back, released by a closure run on each", ctx do
      for mod <- ~w(MapsThenDrains ForThenForeach MapsThenDemonitors) do
        refute named?(reported(ctx.all), "MonitorLeak.#{mod}"), mod
      end
    end

    test "a closure that may give up on one, or a call that stops early, releases none", ctx do
      assert named?(funcs(ctx.all, "wait"), "MonitorLeak.MapsThenGivesUp:-drain/1-fun-0-")
      assert named?(reported(ctx.all), "MonitorLeak.MapsThenFindsOne")
    end

    test "a kill after the grace period, then a wait for the :DOWN, releases it", ctx do
      refute named?(reported(ctx.all), "MonitorLeak.GraceThenKill")
    end

    test "a look with after 0, then a wait for the :DOWN on every path, releases it", ctx do
      refute named?(reported(ctx.all), "MonitorLeak.StopsCursor")
    end

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

    test "a monitor the caller of a client API takes on the server", ctx do
      # ClientSideMonitor.request/2 runs in its caller: the reply path
      # leaves the caller holding one more monitor on the server per call.
      assert named?(funcs(ctx.servers, "wait"), "ClientSideMonitor:request/2")
    end
  end

  describe "the run repeats" do
    test "a monitor a task takes on its way out ends with the task", ctx do
      refute named?(reported(ctx.all), "MonitorLeak.TaskGivesUp")

      # The spawned closure is the watcher's only run: its builder hands it
      # off. InEach's closure, run in the caller, still leaks.
      refute named?(reported(ctx.all), "MonitorLeak.SpawnsWatcher")
    end

    test "a task that monitors in its receive loop takes it again each round", ctx do
      assert named?(funcs(ctx.all, "dropped"), "MonitorLeak.TaskPolls:poll/1")
    end

    test "what only terminate runs ends with the process", ctx do
      # Positive: the same drain, reached from handle_call/3 as well.
      assert named?(reported(ctx.servers), "DrainsOnCall")
      refute named?(reported(ctx.servers), "DrainsOnTerminate")
    end
  end

  describe "the process is one the run can meet again" do
    test "a worker the run itself started is new each time", ctx do
      # Whoever else the pid is handed to, this monitor is the only one
      # this server holds on that worker, and its :DOWN ends both.
      refute named?(reported(ctx.servers), "MonitorsOwnWorker")
      refute named?(reported(ctx.servers), "MonitorsHandedWorker")
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

  describe "released by the caller" do
    test "the supervisor shutdown shape is not reported", ctx do
      # GenStage's ConsumerSupervisor and Horde's ProcessesSupervisor:
      # monitor_child/1 looks once with `after 0` and returns with the
      # monitor live, and terminate_children then waits for every :DOWN.
      refute named?(reported(ctx.all), "MonitorLeak.CollectedByCaller")
    end

    test "the same monitor_child/1 is reported when its caller never waits", ctx do
      assert named?(funcs(ctx.all, "wait"), "MonitorLeak.ReturnsLive:monitor_child/1")
    end

    test "a wait on only some paths after the call does not release it", ctx do
      assert named?(reported(ctx.all), "MonitorLeak.WaitsOnOnePath:monitor_child/1")
    end

    test "one caller that waits does not cover another that does not", ctx do
      assert named?(reported(ctx.all), "MonitorLeak.CollectedOnOneCaller:monitor_child/1")
    end

    test "a caller waiting on the ref it was handed releases it", ctx do
      refute named?(reported(ctx.all), "MonitorLeak.CollectedByRef")
    end

    test "a caller demonitoring the ref it was handed releases it", ctx do
      refute named?(reported(ctx.all), "MonitorLeak.FlushedByCaller")
    end

    test "a caller that drops the ref it was handed loses it", ctx do
      # monitor_and_signal/1 answers its ref; stop/2 throws it away and
      # waits for another monitor's :DOWN.
      assert named?(
               funcs(ctx.all, "dropped"),
               "MonitorLeak.WaitsForAnotherRef:monitor_and_signal/1"
             )
    end

    test "a supervisor fork's monitor_child is released where its caller waits", ctx do
      assert named?(reported(ctx.servers), "ForkShutdownForgets")
      refute Enum.any?(reported(ctx.servers), &String.contains?(&1, "MonitorLeak.ForkShutdown:"))
    end
  end

  describe "ended: the server drops its record and keeps the monitor" do
    test "monitoring on insert and deleting without demonitor is reported", ctx do
      assert funcs(ctx.servers, "ended") == [
               "Argus.Test.Fixtures.MonitorLeak.NeverReleases:handle_call/3"
             ]
    end

    test "a delete that demonitors, and a pop no removal names, are not", ctx do
      refute named?(reported(ctx.servers), "ReleasesOnDelete")
      refute named?(reported(ctx.servers), "KillsMonitored")
    end
  end

  describe "dropped: nothing can release it, and nothing asks first" do
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

    test "a ref a tail call returns is judged by what the caller does with it", ctx do
      dropped = funcs(ctx.servers, "dropped")

      # Positive: a closure handed to Enum.each, and a helper whose caller
      # throws the ref away, lose it as surely as a bare monitor does.
      assert named?(dropped, "EachDropsRefs")
      assert named?(dropped, "ForeachDropsRefs")
      # Any library call that drops what its fun answers (TermFlow.Library).
      assert named?(dropped, "FilterDropsRefs")
      assert named?(dropped, "HelperDropsRef")

      # Quiet: the refs are mapped into a set, or kept in the state.
      refute named?(reported(ctx.servers), "MapsRefs")
      refute named?(reported(ctx.servers), "HelperKeepsRef")
    end
  end
end
