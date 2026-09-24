defmodule Argus.Analyses.BlockingRpcTest do
  use ExUnit.Case, async: true

  alias Argus.Souffle
  alias Argus.Test.Rows

  defp skip_without_souffle do
    unless Souffle.available?(), do: flunk("souffle not installed")
  end

  defp analyze(modules) do
    assert {:ok, results} = Argus.analyze(modules, :blocking)
    results
  end

  defp waits(results, "global"),
    do: Rows.where(results, :blocking, "unbounded_wait", kind: "global", drop: [:kind])

  defp waits(results, kind),
    do:
      Rows.where(results, :blocking, "unbounded_wait", kind: kind, drop: [:kind, :detail, :nodes])

  describe "unbounded_wait: rpc" do
    test "flags :rpc.call without a timeout, not the timeout variant" do
      skip_without_souffle()

      results = analyze([Argus.Test.Fixtures.RpcCaller])
      funcs = Enum.map(waits(results, "rpc"), fn [func, _site, _variant] -> func end)

      assert Enum.any?(funcs, &String.contains?(&1, "call_no_timeout"))
      refute Enum.any?(funcs, &String.contains?(&1, "call_with_timeout"))
    end
  end

  describe "a wait init/1 holds is startup's finding" do
    test "an rpc in init/1, and a :global lock init/1 reaches, are reported once, by startup" do
      skip_without_souffle()

      modules = [Argus.Test.Fixtures.RpcInInit, Argus.Test.Fixtures.GlobalLockInInit]
      results = analyze(modules)
      assert waits(results, "rpc") == []
      assert waits(results, "global") == []

      {:ok, startup} = Argus.analyze(modules, :startup)
      kinds = startup["blocks_on_peer"] |> Enum.map(&Enum.at(&1, 3)) |> Enum.sort()
      assert "global" in kinds and "remote" in kinds
    end
  end

  describe "unbounded_wait: rpc_in_callback" do
    test "flags RPC directly inside handle_call" do
      skip_without_souffle()

      results = analyze([Argus.Test.Fixtures.RpcInCallback])

      assert Enum.any?(waits(results, "rpc_in_callback"), fn [func, _site, _variant] ->
               String.contains?(func, "RpcInCallback:handle_call/3")
             end)
    end

    test "does not flag RPC reached only transitively through a helper" do
      skip_without_souffle()

      # Deliberate direct-only scope: the transitive clause (call_reachable
      # through a guarded dispatcher) produced only false positives on the
      # corpus. The RPC itself is still reported by rpc_without_timeout.
      results = analyze([Argus.Test.Fixtures.RpcViaHelperCallback])

      assert waits(results, "rpc_in_callback") == []

      assert Enum.any?(waits(results, "rpc"), fn [func, _site, _variant] ->
               String.contains?(func, "RpcViaHelperCallback")
             end)
    end
  end

  describe "unbounded_wait: global" do
    test "flags blocking lock acquisition, not zero-retry attempts" do
      skip_without_souffle()

      results = analyze([Argus.Test.Fixtures.GlobalLockModule])

      funcs =
        Enum.map(waits(results, "global"), fn [func, _site, _op, _retries, _nodes] -> func end)

      assert Enum.any?(funcs, &String.contains?(&1, "lock_default"))
      assert Enum.any?(funcs, &String.contains?(&1, "lock_infinity"))
      refute Enum.any?(funcs, &String.contains?(&1, "try_lock_once"))
      refute Enum.any?(funcs, &String.contains?(&1, "del/"))
    end
  end
end
