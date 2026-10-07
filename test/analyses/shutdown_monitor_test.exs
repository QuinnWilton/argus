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
end
