defmodule Argus.Analyses.MailboxMonitorTest do
  use ExUnit.Case

  alias Argus.Souffle
  alias Argus.Test.Fixtures.MonitorLeak, as: M

  @all [M.Leaks, M.Flushes, M.Blocks, M.NoMonitor, M.LeaksThroughHelper, M.FlushesInHelper]

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

  defp funcs do
    assert {:ok, r} = Argus.analyze(@all, :mailbox)
    r |> Map.get("leaked_monitor", []) |> Enum.map(&hd/1) |> Enum.sort()
  end

  defp named?(list, f), do: Enum.any?(list, &String.contains?(&1, f))

  test "a monitor before a timed wait is reported" do
    skip_without_souffle()
    assert named?(funcs(), "MonitorLeak.Leaks")
  end

  test "demonitor with :flush discharges it" do
    skip_without_souffle()

    # Plain demonitor/1 would not: a {:DOWN, ...} already sent stays in the
    # mailbox, and only [:flush] removes it.
    refute named?(funcs(), "MonitorLeak.Flushes")
  end

  test "a receive with no after clause cannot leak" do
    skip_without_souffle()

    # It consumes either the reply or the {:DOWN, ...}. This is the whole
    # discriminator — every monitor-plus-receive in Livebook is this shape,
    # and dropping them is what makes the one real finding worth reading.
    refute named?(funcs(), "MonitorLeak.Blocks")
  end

  test "a timed wait with no monitor has nothing to leak" do
    skip_without_souffle()
    refute named?(funcs(), "MonitorLeak.NoMonitor")
  end

  test "a timed wait one call below the monitor leaks the same way" do
    skip_without_souffle()

    # Finch's HTTP/2 pool: monitor in request/…, the `after` in a private
    # loop. The function reported is the one that established the monitor.
    assert named?(funcs(), "MonitorLeak.LeaksThroughHelper:request/1")
  end

  test "a flush in the helper discharges it" do
    skip_without_souffle()
    refute named?(funcs(), "MonitorLeak.FlushesInHelper")
  end

  describe "over a server's lifetime" do
    defp servers do
      assert {:ok, r} = Argus.analyze(@servers, :mailbox)
      r
    end

    defp mods(r, relation), do: r |> Map.get(relation, []) |> Enum.map(&hd/1) |> Enum.uniq()

    test "monitoring on insert and deleting without demonitor is reported" do
      skip_without_souffle()

      assert mods(servers(), "monitor_never_released") == [
               "Argus.Test.Fixtures.MonitorLeak.NeverReleases"
             ]
    end

    test "a monitor whose ref is thrown away is reported on its own" do
      skip_without_souffle()

      r = servers()

      assert [[mod, site]] = r["monitor_ref_discarded"]
      assert mod == "Argus.Test.Fixtures.MonitorLeak.DropsRef"
      assert site =~ "DropsRef:handle_call/3#"

      # The servers that keep their refs are not reported here, whatever
      # else they do with them.
      refute named?(mods(r, "monitor_ref_discarded"), "NeverReleases")
    end

    test "a monitor in a client API function is the caller's, not the server's" do
      skip_without_souffle()

      refute named?(mods(servers(), "monitor_never_released"), "ClientSideMonitor")
    end
  end
end
