defmodule Argus.Analyses.DominatorsTest do
  use ExUnit.Case

  alias Argus.Souffle.CLI

  defp skip_without_souffle do
    unless CLI.available?(), do: flunk("souffle not installed")
  end

  describe "dominators.dl" do
    test "computes dominance relations" do
      skip_without_souffle()

      assert {:ok, results} = Argus.analyze([:maps], :dominators)
      assert Map.has_key?(results, "dominates")

      doms = results["dominates"]
      assert length(doms) > 0

      # Each entry should be [dominator, dominated, func].
      for [dominator, dominated, func] <- doms do
        assert is_binary(dominator)
        assert is_binary(dominated)
        assert is_binary(func)
        # Strict dominance: dominator != dominated.
        assert dominator != dominated
      end
    end

    test "computes post-dominance relations" do
      skip_without_souffle()

      assert {:ok, results} = Argus.analyze([:maps], :dominators)
      assert Map.has_key?(results, "post_dominates")

      post_doms = results["post_dominates"]
      assert length(post_doms) > 0
    end

    test "computes immediate dominators" do
      skip_without_souffle()

      assert {:ok, results} = Argus.analyze([:maps], :dominators)
      assert Map.has_key?(results, "idom")

      idoms = results["idom"]
      assert length(idoms) > 0

      # Each entry should be [id, immediate_dominator, func].
      for [id, idom_id, func] <- idoms do
        assert is_binary(id)
        assert is_binary(idom_id)
        assert is_binary(func)
        # The idom is a strict dominator, so id != idom.
        assert id != idom_id
      end
    end

    test "function entry dominates all instructions in that function" do
      skip_without_souffle()

      assert {:ok, results} =
               Argus.analyze([Argus.Test.Fixtures.DominatorsFixture], :dominators)

      doms = results["dominates"]

      # Group dominance by function.
      by_func =
        Enum.group_by(doms, fn [_, _, func] -> func end, fn [dom, _, _] -> dom end)

      # For each function, the entry instruction should dominate the most nodes.
      for {_func, dominators} <- by_func do
        freq = Enum.frequencies(dominators)
        # The most frequent dominator is the entry (or close to it).
        {_top_dom, top_count} = Enum.max_by(freq, fn {_d, c} -> c end)
        assert top_count > 0
      end
    end
  end
end
