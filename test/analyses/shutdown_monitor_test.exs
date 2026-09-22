defmodule Argus.Analyses.ShutdownMonitorTest do
  use ExUnit.Case

  alias Argus.Souffle
  alias Argus.Test.Fixtures.MonitorLeak, as: M

  @servers [
    M.NeverReleases,
    M.ReleasesOnDelete,
    M.KillsMonitored,
    M.ClientSideMonitor,
    M.DropsRef
  ]

  defp skip_without_souffle do
    unless Souffle.available?(), do: flunk("souffle not installed")
  end

  describe "over a server's lifetime" do
    defp servers do
      assert {:ok, r} = Argus.analyze(@servers, :shutdown)
      r
    end

    test "terminating a monitored child without demonitor is reported" do
      skip_without_souffle()

      r = servers()

      assert [[mod, site, kill_site]] = r["kills_monitored_child"]
      assert mod == "Argus.Test.Fixtures.MonitorLeak.KillsMonitored"
      assert site =~ "KillsMonitored:handle_call/3#"
      assert kill_site =~ "KillsMonitored:handle_cast/2#"
    end
  end
end
