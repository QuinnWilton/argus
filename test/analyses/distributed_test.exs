defmodule Argus.Analyses.DistributedTest do
  use ExUnit.Case

  alias Argus.Souffle

  defp skip_without_souffle do
    unless Souffle.available?(), do: flunk("souffle not installed")
  end

  defp analyze(modules) do
    assert {:ok, results} = Argus.analyze(modules, :distributed)
    results
  end

  describe "rpc_without_timeout" do
    test "flags :rpc.call without a timeout, not the timeout variant" do
      skip_without_souffle()

      results = analyze([Argus.Test.Fixtures.RpcCaller])
      funcs = Enum.map(results["rpc_without_timeout"], fn [func, _variant, _site] -> func end)

      assert Enum.any?(funcs, &String.contains?(&1, "call_no_timeout"))
      refute Enum.any?(funcs, &String.contains?(&1, "call_with_timeout"))
    end
  end

  describe "global_register_risk" do
    test "flags register_name/2 but not register_name/3 with a resolver" do
      skip_without_souffle()

      results = analyze([Argus.Test.Fixtures.GlobalRegisterModule])
      funcs = Enum.map(results["global_register_risk"], fn [func, _name, _site] -> func end)

      # register/1 wraps :global.register_name/2 — the race-prone default.
      assert Enum.any?(funcs, &String.contains?(&1, "register/"))

      # register_with_resolve/2 wraps register_name/3, which supplies an
      # explicit conflict-resolution function — the fixed form.
      refute Enum.any?(funcs, &String.contains?(&1, "register_with_resolve"))
    end
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

  describe "rpc_in_genserver_callback" do
    test "flags RPC directly inside handle_call" do
      skip_without_souffle()

      results = analyze([Argus.Test.Fixtures.RpcInCallback])

      assert Enum.any?(results["rpc_in_genserver_callback"], fn [func, _variant] ->
               String.contains?(func, "RpcInCallback:handle_call/3")
             end)
    end

    test "does not flag RPC reached only transitively through a helper" do
      skip_without_souffle()

      # Deliberate direct-only scope: the transitive clause (call_reachable
      # through a guarded dispatcher) produced only false positives on the
      # corpus. The RPC itself is still reported by rpc_without_timeout.
      results = analyze([Argus.Test.Fixtures.RpcViaHelperCallback])

      assert results["rpc_in_genserver_callback"] == []

      assert Enum.any?(results["rpc_without_timeout"], fn [func, _variant, _site] ->
               String.contains?(func, "RpcViaHelperCallback")
             end)
    end
  end

  describe "global_blocking_op" do
    test "flags blocking lock acquisition, not zero-retry attempts" do
      skip_without_souffle()

      results = analyze([Argus.Test.Fixtures.GlobalLockModule])

      funcs =
        Enum.map(results["global_blocking_op"], fn [func, _op, _retries, _site] -> func end)

      assert Enum.any?(funcs, &String.contains?(&1, "lock_default"))
      assert Enum.any?(funcs, &String.contains?(&1, "lock_infinity"))
      refute Enum.any?(funcs, &String.contains?(&1, "try_lock_once"))
      refute Enum.any?(funcs, &String.contains?(&1, "del/"))
    end
  end
end
