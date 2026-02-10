defmodule Argus.RulesTest do
  use ExUnit.Case

  alias Argus.Extract
  alias Argus.Souffle.CLI

  @moduletag :tmp_dir

  defp skip_without_souffle do
    unless CLI.available?(), do: flunk("souffle not installed")
  end

  defp priv_dl(name), do: Path.join(:code.priv_dir(:argus), "dl/#{name}")

  describe "cfg.dl" do
    @tag :tmp_dir
    test "derives cfg_edge from a real module", %{tmp_dir: tmp_dir} do
      skip_without_souffle()

      facts_dir = Path.join(tmp_dir, "facts")
      {:ok, _} = Extract.run([:lists], facts_dir)

      assert {:ok, results} = CLI.run(facts_dir, priv_dl("analyses/cfg.dl"))
      assert Map.has_key?(results, "cfg_edge")

      edges = results["cfg_edge"]
      assert length(edges) > 0

      # Every edge should be a pair of instruction IDs.
      for [from, to] <- edges do
        assert is_binary(from)
        assert is_binary(to)
      end
    end
  end

  describe "callgraph.dl" do
    @tag :tmp_dir
    test "derives call_edge from a real module", %{tmp_dir: tmp_dir} do
      skip_without_souffle()

      facts_dir = Path.join(tmp_dir, "facts")
      {:ok, _} = Extract.run([Enum], facts_dir)

      assert {:ok, results} = CLI.run(facts_dir, priv_dl("analyses/callgraph.dl"))
      assert Map.has_key?(results, "call_edge")

      edges = results["call_edge"]
      assert length(edges) > 0

      # Enum should call :lists:reverse/1 (or similar).
      callee_strs = Enum.map(edges, fn [_caller, callee] -> callee end)
      assert Enum.any?(callee_strs, &String.contains?(&1, "reverse"))
    end
  end

  describe "reachability.dl" do
    @tag :tmp_dir
    test "derives transitive reachability", %{tmp_dir: tmp_dir} do
      skip_without_souffle()

      facts_dir = Path.join(tmp_dir, "facts")
      # Use a small module for speed.
      {:ok, _} = Extract.run([:maps], facts_dir)

      assert {:ok, results} = CLI.run(facts_dir, priv_dl("analyses/reachability.dl"))

      # Should have both CFG and call reachability results.
      assert Map.has_key?(results, "cfg_reachable")
      assert Map.has_key?(results, "call_reachable")

      assert length(results["cfg_reachable"]) > 0
    end
  end
end
