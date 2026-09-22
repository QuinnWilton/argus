defmodule Argus.Analyses.BlockingRpcTest do
  use ExUnit.Case

  alias Argus.Souffle

  defp skip_without_souffle do
    unless Souffle.available?(), do: flunk("souffle not installed")
  end

  defp analyze(modules) do
    assert {:ok, results} = Argus.analyze(modules, :blocking)
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
