defmodule Argus.Analyses.ShutdownMonitorTest do
  use ExUnit.Case, async: true
  @moduletag :flowlog

  alias Argus.Test.Fixtures.MonitorLeak, as: M
  alias Argus.Test.Memo

  @servers [
    M.NeverReleases,
    M.ReleasesOnDelete,
    M.KillsMonitored,
    M.ClientSideMonitor,
    M.DropsRef
  ]

  describe "over a server's lifetime" do
    defp servers do
      assert {:ok, r} = Memo.analyze(@servers, :shutdown)
      r
    end

    test "terminating a monitored child without demonitor is reported" do
      r = servers()

      assert [[mod, site, kill_site]] = r["kills_monitored_child"]
      assert mod == "Argus.Test.Fixtures.MonitorLeak.KillsMonitored"
      assert site =~ "KillsMonitored:handle_call/3#"
      assert kill_site =~ "KillsMonitored:handle_cast/2#"
    end

    test "a stop the server makes from a process it spawns is still its doing" do
      assert {:ok, r} = Memo.analyze([M.KillsMonitoredAside], :shutdown)
      assert [[mod, _site, kill_site]] = r["kills_monitored_child"]
      assert mod == "Argus.Test.Fixtures.MonitorLeak.KillsMonitoredAside"
      assert kill_site =~ "KillsMonitoredAside:-handle_cast/2-fun-0-/1#"
    end
  end

  describe "stops whose :DOWN the crash clause cannot see" do
    alias Argus.Test.Fixtures.ShutdownMonitors, as: SM

    defp killers(mods) do
      assert {:ok, r} = Memo.analyze(mods, :shutdown)
      r |> Map.get("kills_monitored_child", []) |> Enum.map(&hd/1) |> Enum.uniq()
    end

    test "a stop made from terminate/2 is not reported" do
      assert killers([SM.StopsInTerminate]) == []
    end

    test "the same stop in a helper a cast runs too is reported" do
      assert killers([SM.StopsInTerminateAndCast]) ==
               ["Argus.Test.Fixtures.ShutdownMonitors.StopsInTerminateAndCast"]
    end

    test "a stop of a process the server started cannot pair with a monitor of its init argument" do
      assert killers([SM.OwnerAndWatchers, SM.Lib]) == []
    end

    test "nor can a stop of one a start_link outside the program started" do
      # Lib left out, as volt's FileSystem dependency is: its start is
      # out of sight, and the pid it answers still a process born there.
      assert killers([SM.OwnerAndWatchers]) == []
    end

    test "a stop of the monitored init argument itself is reported" do
      assert killers([SM.StopsOwner]) == ["Argus.Test.Fixtures.ShutdownMonitors.StopsOwner"]
    end

    test "a demonitor in the callback that spawns the stop releases the monitor" do
      assert killers([SM.DemonitorsThenSpawnsStop]) == []
    end

    test "a demonitor only in another callback does not" do
      assert killers([SM.SpawnsStopDemonitorsElsewhere]) ==
               ["Argus.Test.Fixtures.ShutdownMonitors.SpawnsStopDemonitorsElsewhere"]
    end
  end
end
