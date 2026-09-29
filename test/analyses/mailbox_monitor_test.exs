defmodule Argus.Analyses.MailboxMonitorTest do
  @moduledoc """
  `monitor_leak`: a monitor that code which runs again takes again before
  the one before it is released (docs/design/monitor-leaks.md). Each
  describe block is one part of the model: the run repeats, the process
  is one it can meet again, the run does not release it, and one of the
  three witnesses shows the monitor before is still live.
  """
  use ExUnit.Case, async: true

  alias Argus.Souffle
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

  defp skip_without_souffle do
    unless Souffle.available?(), do: flunk("souffle not installed")
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
      skip_without_souffle()
      assert named?(funcs(ctx.all, "wait"), "MonitorLeak.Leaks:wait/1")
    end

    test "the answer path of a wait with no `after` keeps it too", ctx do
      skip_without_souffle()

      # Blocks takes the :DOWN or the reply; on the reply the monitor stays
      # live, and the next call monitors the same process again.
      assert named?(funcs(ctx.all, "wait"), "MonitorLeak.Blocks:wait/1")
    end

    test "a demonitor with :flush on every way out releases it", ctx do
      skip_without_souffle()
      refute named?(reported(ctx.all), "MonitorLeak.Flushes")
    end

    test "a timed wait with no monitor has nothing to leak", ctx do
      skip_without_souffle()
      refute named?(reported(ctx.all), "MonitorLeak.NoMonitor")
    end

    test "a wait one call below the monitor", ctx do
      skip_without_souffle()

      # Finch's HTTP/2 pool shape: monitor in request/1, the `after` in a
      # private loop. The function reported is the one that monitors.
      assert named?(funcs(ctx.all, "wait"), "MonitorLeak.LeaksThroughHelper:request/1")
    end

    test "a helper handed the ref that releases it on every way out releases it", ctx do
      skip_without_souffle()
      refute named?(reported(ctx.all), "MonitorLeak.FlushesInHelper")
    end

    test "a wait in a closure the caller runs", ctx do
      skip_without_souffle()
      assert named?(funcs(ctx.all, "wait"), "MonitorLeak.InEach:-wait_all/1-fun-0-")
    end

    test "a kill after the grace period, then a wait for the :DOWN, releases it", ctx do
      skip_without_souffle()
      refute named?(reported(ctx.all), "MonitorLeak.GraceThenKill")
    end

    test "a look with after 0, then a wait for the :DOWN on every path, releases it", ctx do
      skip_without_souffle()
      refute named?(reported(ctx.all), "MonitorLeak.StopsCursor")
    end

    test "a wait in the logger's machinery is not the monitoring function's" do
      skip_without_souffle()

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
      skip_without_souffle()

      # ClientSideMonitor.request/2 runs in its caller: the reply path
      # leaves the caller holding one more monitor on the server per call.
      assert named?(funcs(ctx.servers, "wait"), "ClientSideMonitor:request/2")
    end
  end

  describe "the run repeats" do
    test "a monitor a task takes on its way out ends with the task", ctx do
      skip_without_souffle()
      refute named?(reported(ctx.all), "MonitorLeak.TaskGivesUp")

      # The spawned closure is the watcher's only run: its builder hands it
      # off. InEach's closure, run in the caller, still leaks.
      refute named?(reported(ctx.all), "MonitorLeak.SpawnsWatcher")
    end

    test "a task that monitors in its receive loop takes it again each round", ctx do
      skip_without_souffle()
      assert named?(funcs(ctx.all, "dropped"), "MonitorLeak.TaskPolls:poll/1")
    end

    test "what only terminate runs ends with the process", ctx do
      skip_without_souffle()

      # Positive: the same drain, reached from handle_call/3 as well.
      assert named?(reported(ctx.servers), "DrainsOnCall")
      refute named?(reported(ctx.servers), "DrainsOnTerminate")
    end
  end

  describe "the process is one the run can meet again" do
    test "a worker the run itself started is new each time", ctx do
      skip_without_souffle()

      # Whoever else the pid is handed to, this monitor is the only one
      # this server holds on that worker, and its :DOWN ends both.
      refute named?(reported(ctx.servers), "MonitorsOwnWorker")
      refute named?(reported(ctx.servers), "MonitorsHandedWorker")
    end

    test "a worker a start answered through the program's wrappers is new each time" do
      skip_without_souffle()

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

  describe "released by the caller" do
    test "the supervisor shutdown shape is not reported", ctx do
      skip_without_souffle()

      # GenStage's ConsumerSupervisor and Horde's ProcessesSupervisor:
      # monitor_child/1 looks once with `after 0` and returns with the
      # monitor live, and terminate_children then waits for every :DOWN.
      refute named?(reported(ctx.all), "MonitorLeak.CollectedByCaller")
    end

    test "the same monitor_child/1 is reported when its caller never waits", ctx do
      skip_without_souffle()
      assert named?(funcs(ctx.all, "wait"), "MonitorLeak.ReturnsLive:monitor_child/1")
    end

    test "a wait on only some paths after the call does not release it", ctx do
      skip_without_souffle()
      assert named?(reported(ctx.all), "MonitorLeak.WaitsOnOnePath:monitor_child/1")
    end

    test "one caller that waits does not cover another that does not", ctx do
      skip_without_souffle()
      assert named?(reported(ctx.all), "MonitorLeak.CollectedOnOneCaller:monitor_child/1")
    end

    test "a caller waiting on the ref it was handed releases it", ctx do
      skip_without_souffle()
      refute named?(reported(ctx.all), "MonitorLeak.CollectedByRef")
    end

    test "a caller demonitoring the ref it was handed releases it", ctx do
      skip_without_souffle()
      refute named?(reported(ctx.all), "MonitorLeak.FlushedByCaller")
    end

    test "a caller that drops the ref it was handed loses it", ctx do
      skip_without_souffle()

      # monitor_and_signal/1 answers its ref; stop/2 throws it away and
      # waits for another monitor's :DOWN.
      assert named?(
               funcs(ctx.all, "dropped"),
               "MonitorLeak.WaitsForAnotherRef:monitor_and_signal/1"
             )
    end

    test "a supervisor fork's monitor_child is released where its caller waits", ctx do
      skip_without_souffle()

      assert named?(reported(ctx.servers), "ForkShutdownForgets")
      refute Enum.any?(reported(ctx.servers), &String.contains?(&1, "MonitorLeak.ForkShutdown:"))
    end
  end

  describe "ended: the server drops its record and keeps the monitor" do
    test "monitoring on insert and deleting without demonitor is reported", ctx do
      skip_without_souffle()

      assert funcs(ctx.servers, "ended") == [
               "Argus.Test.Fixtures.MonitorLeak.NeverReleases:handle_call/3"
             ]
    end

    test "a delete that demonitors, and a pop no removal names, are not", ctx do
      skip_without_souffle()
      refute named?(reported(ctx.servers), "ReleasesOnDelete")
      refute named?(reported(ctx.servers), "KillsMonitored")
    end
  end

  describe "dropped: nothing can release it, and nothing asks first" do
    test "a monitor whose ref is thrown away is reported at its site", ctx do
      skip_without_souffle()

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
      skip_without_souffle()

      dropped = funcs(ctx.servers, "dropped")

      # Positive: a closure handed to Enum.each, and a helper whose caller
      # throws the ref away, lose it as surely as a bare monitor does.
      assert named?(dropped, "EachDropsRefs")
      assert named?(dropped, "ForeachDropsRefs")
      assert named?(dropped, "HelperDropsRef")

      # Quiet: the refs are mapped into a set, or kept in the state.
      refute named?(reported(ctx.servers), "MapsRefs")
      refute named?(reported(ctx.servers), "HelperKeepsRef")
    end
  end
end
