defmodule Argus.Analyses.MonitorLeakTest do
  use ExUnit.Case

  alias Argus.Souffle
  alias Argus.Test.Fixtures.MonitorLeak, as: M

  @all [M.Leaks, M.Flushes, M.Blocks, M.NoMonitor]

  defp skip_without_souffle do
    unless Souffle.available?(), do: flunk("souffle not installed")
  end

  defp funcs do
    assert {:ok, r} = Argus.analyze(@all, :monitor_leak)
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
end
