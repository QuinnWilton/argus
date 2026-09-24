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
    M.TaskPolls,
    M.CollectedByCaller,
    M.ReturnsLive,
    M.WaitsOnOnePath,
    M.CollectedOnOneCaller,
    M.CollectedByRef,
    M.FlushedByCaller,
    M.WaitsForAnotherRef,
    M.GraceThenKill
  ]

  @servers [
    M.NeverReleases,
    M.ReleasesOnDelete,
    M.KillsMonitored,
    M.ClientSideMonitor,
    M.DropsRef
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
    # One that waits again carries the stale :DOWN into its next wait.
    assert named?(funcs(ctx), "MonitorLeak.TaskPolls:poll/1")
  end

  test "a kill after the grace period, then a wait for the :DOWN, waits it out", ctx do
    skip_without_souffle()
    refute named?(funcs(ctx), "MonitorLeak.GraceThenKill")
  end

  test "a flush in the helper discharges it", ctx do
    skip_without_souffle()
    refute named?(funcs(ctx), "MonitorLeak.FlushesInHelper")
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

      assert mods(servers(), "never_released") == [
               "Argus.Test.Fixtures.MonitorLeak.NeverReleases"
             ]
    end

    test "a monitor whose ref is thrown away is reported on its own" do
      skip_without_souffle()

      r = servers()

      assert [[mod, site]] =
               Rows.where(r, :mailbox, "unconsumed_monitor",
                 kind: "ref_discarded",
                 drop: [:func, :kind]
               )

      assert mod == "Argus.Test.Fixtures.MonitorLeak.DropsRef"
      assert site =~ "DropsRef:handle_call/3#"

      # The servers that keep their refs are not reported here, whatever
      # else they do with them.
      refute named?(mods(r, "ref_discarded"), "NeverReleases")
    end

    test "a monitor in a client API function is the caller's, not the server's" do
      skip_without_souffle()

      refute named?(mods(servers(), "never_released"), "ClientSideMonitor")
    end
  end
end
