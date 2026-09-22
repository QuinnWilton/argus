defmodule Argus.Analyses.StartupDistributedTest do
  use ExUnit.Case

  alias Argus.Souffle

  defp skip_without_souffle do
    unless Souffle.available?(), do: flunk("souffle not installed")
  end

  defp analyze(modules) do
    assert {:ok, results} = Argus.analyze(modules, :startup)
    results
  end

  describe "distributed_in_init" do
    test "flags RPC in a behaviour module's init/1" do
      skip_without_souffle()

      results = analyze([Argus.Test.Fixtures.RpcInInit])

      assert Enum.any?(results["distributed_in_init"], fn [func, _op, _site] ->
               String.contains?(func, "RpcInInit:init/1")
             end)
    end

    test "flags Node.connect in init/1" do
      skip_without_souffle()

      results = analyze([Argus.Test.Fixtures.ConnectInInit])

      assert Enum.any?(results["distributed_in_init"], fn [func, op, _site] ->
               String.contains?(func, "ConnectInInit:init/1") and op == "connect"
             end)
    end

    test "does not flag a plain module's init/1" do
      skip_without_souffle()

      # PlainInit implements no behaviour: its init/1 is an ordinary
      # function that never runs at supervisor start time.
      results = analyze([Argus.Test.Fixtures.PlainInit])

      assert results["distributed_in_init"] == []
    end

    test "does not flag :net_kernel.monitor_nodes in init/1" do
      skip_without_souffle()

      # monitor_nodes is a subscription flag — non-blocking.
      results = analyze([Argus.Test.Fixtures.NodeMonitorServer])

      assert results["distributed_in_init"] == []
    end
  end
end
