defmodule Argus.Analyses.MailboxMonitorTest do
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

  # Every test reads the same solve of @all: solved once, read-only.
  setup_all do
    %{solved: Memo.analyze(@all, :mailbox)}
  end

  defp skip_without_souffle do
    unless Souffle.available?(), do: flunk("souffle not installed")
  end

  defp funcs(%{solved: solved}) do
    assert {:ok, r} = solved

    r
    |> Rows.where(:mailbox, "unconsumed_monitor", kind: "timed_wait")
    |> Enum.map(&Enum.at(&1, 1))
    |> Enum.sort()
  end

  defp named?(list, f), do: Enum.any?(list, &String.contains?(&1, f))

  test "a monitor before a timed wait is reported", ctx do
    skip_without_souffle()
    assert named?(funcs(ctx), "MonitorLeak.Leaks")
  end

  test "demonitor with :flush discharges it", ctx do
    skip_without_souffle()

    # Plain demonitor/1 would not: a {:DOWN, ...} already sent stays in the
    # mailbox, and only [:flush] removes it.
    refute named?(funcs(ctx), "MonitorLeak.Flushes")
  end

  test "a receive with no after clause cannot leak", ctx do
    skip_without_souffle()

    # It consumes either the reply or the {:DOWN, ...}. This is the whole
    # discriminator — every monitor-plus-receive in Livebook is this shape,
    # and dropping them is what makes the one real finding worth reading.
    refute named?(funcs(ctx), "MonitorLeak.Blocks")
  end

  test "a timed wait with no monitor has nothing to leak", ctx do
    skip_without_souffle()
    refute named?(funcs(ctx), "MonitorLeak.NoMonitor")
  end

  test "a timed wait one call below the monitor leaks the same way", ctx do
    skip_without_souffle()

    # Finch's HTTP/2 pool: monitor in request/…, the `after` in a private
    # loop. The function reported is the one that established the monitor.
    assert named?(funcs(ctx), "MonitorLeak.LeaksThroughHelper:request/1")
  end

  test "a wait in a closure the caller runs leaks in the caller", ctx do
    skip_without_souffle()
    assert named?(funcs(ctx), "MonitorLeak.InEach:-wait_all/1-fun-0-")
  end

  test "a monitor a task leaves on its way out ends with the task", ctx do
    skip_without_souffle()
    refute named?(funcs(ctx), "MonitorLeak.TaskGivesUp")
    # The spawned closure itself is the watcher's last act (its builder
    # only hands it off); InEach's closure, run in the caller, still leaks.
    refute named?(funcs(ctx), "MonitorLeak.SpawnsWatcher")
    assert named?(funcs(ctx), "MonitorLeak.InEach:-wait_all/1-fun-0-")
    # One that waits again carries the stale :DOWN into its next wait.
    assert named?(funcs(ctx), "MonitorLeak.TaskPolls:poll/1")
  end

  test "a kill after the grace period, then a wait for the :DOWN, waits it out", ctx do
    skip_without_souffle()
    refute named?(funcs(ctx), "MonitorLeak.GraceThenKill")
  end

  test "a look with after 0, then a wait for the :DOWN on every path, waits it out", ctx do
    skip_without_souffle()
    refute named?(funcs(ctx), "MonitorLeak.StopsCursor")
  end

  test "a flush in the helper discharges it", ctx do
    skip_without_souffle()
    refute named?(funcs(ctx), "MonitorLeak.FlushesInHelper")
  end

  test "a timed wait in the logger's machinery is not the monitoring function's" do
    skip_without_souffle()

    # With OTP's logger and gen in the program, :logger.error/1 reaches
    # gen's timed receive through a handler's removal: a side path
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

    leaks =
      r
      |> Rows.where(:mailbox, "unconsumed_monitor", kind: "timed_wait")
      |> Enum.map(&Enum.at(&1, 1))

    assert "Argus.Test.Fixtures.MonitorLeak.LogsAndLeaks:watch/1" in leaks
    refute "Argus.Test.Fixtures.MonitorLeak.LogsAfterMonitor:watch/1" in leaks
  end

  describe "a monitor the caller goes on to collect" do
    test "the supervisor shutdown shape is not reported", ctx do
      skip_without_souffle()

      # GenStage's ConsumerSupervisor and Horde's ProcessesSupervisor:
      # monitor_child/1 looks once with `after 0` and returns with the
      # monitor live, and terminate_children then waits for every :DOWN.
      refute named?(funcs(ctx), "MonitorLeak.CollectedByCaller")
    end

    test "the same monitor_child/1 is reported when its caller never waits", ctx do
      skip_without_souffle()
      assert named?(funcs(ctx), "MonitorLeak.ReturnsLive:monitor_child/1")
    end

    test "a wait on only some paths after the call does not collect it", ctx do
      skip_without_souffle()
      assert named?(funcs(ctx), "MonitorLeak.WaitsOnOnePath:monitor_child/1")
    end

    test "one caller that waits does not cover another that does not", ctx do
      skip_without_souffle()
      assert named?(funcs(ctx), "MonitorLeak.CollectedOnOneCaller:monitor_child/1")
    end

    test "a caller waiting on the ref it was handed collects it", ctx do
      skip_without_souffle()
      refute named?(funcs(ctx), "MonitorLeak.CollectedByRef")
    end

    test "a caller demonitoring the ref it was handed with :flush collects it", ctx do
      skip_without_souffle()
      refute named?(funcs(ctx), "MonitorLeak.FlushedByCaller")
    end

    test "a caller waiting on another monitor's :DOWN does not", ctx do
      skip_without_souffle()
      assert named?(funcs(ctx), "MonitorLeak.WaitsForAnotherRef:monitor_and_signal/1")
    end
  end

  describe "over a server's lifetime" do
    defp servers do
      assert {:ok, r} = Memo.analyze(@servers, :mailbox)
      r
    end

    defp mods(r, kind),
      do:
        r
        |> Rows.where(:mailbox, "unconsumed_monitor", kind: kind)
        |> Enum.map(&hd/1)
        |> Enum.uniq()

    test "monitoring on insert and deleting without demonitor is reported" do
      skip_without_souffle()

      # DrainsOnCall is this rule's too (its drain also runs from a call).
      assert mods(servers(), "never_released") -- ["Argus.Test.Fixtures.MonitorLeak.DrainsOnCall"] ==
               ["Argus.Test.Fixtures.MonitorLeak.NeverReleases"]
    end

    test "a monitor whose ref is thrown away is reported on its own" do
      skip_without_souffle()

      r = servers()

      rows =
        Rows.where(r, :mailbox, "unconsumed_monitor",
          kind: "ref_discarded",
          drop: [:func, :kind]
        )

      assert [site] =
               for(
                 [mod, site] <- rows,
                 mod == "Argus.Test.Fixtures.MonitorLeak.DropsRef",
                 do: site
               )

      assert site =~ "DropsRef:handle_call/3#"

      # The servers that keep their refs are not reported here, whatever
      # else they do with them.
      refute named?(mods(r, "ref_discarded"), "NeverReleases")
    end

    test "a ref a tail call returns is judged by what the caller does with it" do
      skip_without_souffle()

      discarded = mods(servers(), "ref_discarded")

      # Positive: a closure handed to Enum.each, and a helper whose caller
      # throws the ref away, lose it as surely as a bare monitor does.
      assert named?(discarded, "EachDropsRefs")
      assert named?(discarded, "ForeachDropsRefs")
      assert named?(discarded, "HelperDropsRef")

      # Quiet: the refs are mapped into a set, or kept in the state.
      refute named?(discarded, "MapsRefs")
      refute named?(discarded, "HelperKeepsRef")
    end

    test "what only terminate runs ends with the process" do
      skip_without_souffle()

      r = servers()
      reported = Enum.flat_map(~w(never_released ref_discarded timed_wait), &mods(r, &1))

      # Positive: the same drain, reached from handle_call/3 as well.
      assert named?(reported, "DrainsOnCall")
      refute named?(reported, "DrainsOnTerminate")
    end

    test "a supervisor fork's monitor_child is collected where its caller waits" do
      skip_without_souffle()

      r = servers()

      # Positive: the caller's :ok side forgets the :DOWN.
      assert named?(mods(r, "ref_discarded"), "ForkShutdownForgets")
      assert named?(mods(r, "timed_wait"), "ForkShutdownForgets")

      refute Enum.any?(mods(r, "ref_discarded"), &(&1 == inspect(M.ForkShutdown)))
      refute Enum.any?(mods(r, "timed_wait"), &(&1 == inspect(M.ForkShutdown)))
    end

    test "a monitor on a worker the server started and keeps needs no ref" do
      skip_without_souffle()

      discarded = mods(servers(), "ref_discarded")

      # Positive: the pid is cast to another server as data.
      assert named?(discarded, "MonitorsHandedWorker")
      refute named?(discarded, "MonitorsOwnWorker")
    end

    test "a monitor in a client API function is the caller's, not the server's" do
      skip_without_souffle()

      refute named?(mods(servers(), "never_released"), "ClientSideMonitor")
    end
  end
end
