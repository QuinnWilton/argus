defmodule Argus.Analyses.StartupDistributedTest do
  use ExUnit.Case, async: true
  @moduletag :flowlog

  alias Argus.Test.Memo
  alias Argus.Test.Rows

  defp analyze(modules) do
    assert {:ok, results} = Memo.analyze(modules, :startup)
    results
  end

  defp remote(results),
    do:
      Rows.where(results, :startup, "blocks_on_peer",
        kind: "remote",
        drop: [:phase, :dep, :kind, :ordering, :sup]
      )

  describe "blocks_on_peer: remote" do
    test "flags RPC in a behaviour module's init/1" do
      results = analyze([Argus.Test.Fixtures.RpcInInit])

      assert Enum.any?(remote(results), fn [func, _site, _op] ->
               String.contains?(func, "RpcInInit:init/1")
             end)
    end

    test "flags an rpc init/1 reaches through a helper on its own stack" do
      results = analyze([Argus.Test.Fixtures.RpcViaHelperInInit])
      rows = remote(results)

      assert [["Argus.Test.Fixtures.RpcViaHelperInInit:init/1", site, "rpc"]] = rows
      assert site =~ "RpcViaHelperInInit:fetch/1#"
    end

    test "does not flag an rpc in a process init/1 starts" do
      results = analyze([Argus.Test.Fixtures.RpcSpawnedFromInit])

      assert remote(results) == []
    end

    test "flags Node.connect in init/1" do
      results = analyze([Argus.Test.Fixtures.ConnectInInit])

      assert Enum.any?(remote(results), fn [func, _site, op] ->
               String.contains?(func, "ConnectInInit:init/1") and op == "connect"
             end)
    end

    test "flags a spawn on another node in init/1, not one on its own" do
      assert [["Argus.Test.Fixtures.SpawnThereInInit:init/1", _site, "spawn"]] =
               remote(analyze([Argus.Test.Fixtures.SpawnThereInInit]))

      assert remote(analyze([Argus.Test.Fixtures.SpawnHereInInit])) == []
    end

    test "does not flag a plain module's init/1" do
      # PlainInit implements no behaviour: its init/1 is an ordinary
      # function that never runs at supervisor start time.
      results = analyze([Argus.Test.Fixtures.PlainInit])

      assert remote(results) == []
    end

    test "flags a Mnesia read in init/1" do
      results = analyze([Argus.Test.Fixtures.StartupMnesiaInInit])

      assert [["Argus.Test.Fixtures.StartupMnesiaInInit:init/1", _site, "dirty_read"]] =
               remote(results)
    end

    test "does not flag a local DETS table read in init/1" do
      # DETS is a file on this node: no peer can be slow or partitioned.
      results = analyze([Argus.Test.Fixtures.StartupDetsInInit])

      assert remote(results) == []
    end

    test "does not flag :net_kernel.monitor_nodes in init/1" do
      # monitor_nodes is a subscription flag — non-blocking.
      results = analyze([Argus.Test.Fixtures.NodeMonitorServer])

      assert remote(results) == []
    end
  end
end
