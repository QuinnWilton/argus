defmodule Argus.Analyses.CallgraphCtxTest do
  use ExUnit.Case

  alias Argus.Souffle.CLI

  defp skip_without_souffle do
    unless CLI.available?(), do: flunk("souffle not installed")
  end

  describe "callgraph_ctx.dl" do
    test "produces call_edge_ctx with 3-column entries" do
      skip_without_souffle()

      assert {:ok, results} = Argus.analyze([Enum, :lists], :callgraph_ctx)
      assert Map.has_key?(results, "call_edge_ctx")

      edges = results["call_edge_ctx"]
      assert length(edges) > 0

      # Each entry should be [caller, callee, site].
      for [caller, callee, site] <- edges do
        assert is_binary(caller)
        assert is_binary(callee)
        assert is_binary(site)
      end
    end

    test "computes call_site_fan_out" do
      skip_without_souffle()

      assert {:ok, results} = Argus.analyze([Enum], :callgraph_ctx)
      assert Map.has_key?(results, "call_site_fan_out")

      fan_out = results["call_site_fan_out"]
      assert length(fan_out) > 0

      # Each call site in static BEAM code has exactly 1 callee (fan-out == 1).
      for [_site, n] <- fan_out do
        assert n == "1"
      end
    end

    test "computes function_call_site_count" do
      skip_without_souffle()

      assert {:ok, results} = Argus.analyze([Enum], :callgraph_ctx)
      assert Map.has_key?(results, "function_call_site_count")

      counts = results["function_call_site_count"]
      assert length(counts) > 0

      # All counts should be non-negative integers.
      for [_func, n] <- counts do
        assert String.to_integer(n) >= 0
      end

      # At least some functions should have call sites.
      assert Enum.any?(counts, fn [_func, n] -> String.to_integer(n) > 0 end)
    end

    test "computes call_reachable_ctx" do
      skip_without_souffle()

      assert {:ok, results} = Argus.analyze([Enum, :lists], :callgraph_ctx)
      assert Map.has_key?(results, "call_reachable_ctx")

      reachable = results["call_reachable_ctx"]
      assert length(reachable) > 0

      # Each entry should be [from, to, origin_site].
      for [from, to, origin_site] <- reachable do
        assert is_binary(from)
        assert is_binary(to)
        assert is_binary(origin_site)
      end
    end

    test "also produces context-insensitive call_edge" do
      skip_without_souffle()

      assert {:ok, results} = Argus.analyze([Enum], :callgraph_ctx)
      assert Map.has_key?(results, "call_edge")
      assert length(results["call_edge"]) > 0
    end
  end
end
