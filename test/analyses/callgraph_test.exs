defmodule Argus.Analyses.CallgraphTest do
  use ExUnit.Case

  alias Argus.Extract
  alias Argus.Souffle.CLI

  @moduletag :tmp_dir

  defp skip_without_souffle do
    unless CLI.available?(), do: flunk("souffle not installed")
  end

  defp priv_dl(name), do: Path.join(:code.priv_dir(:argus), "dl/#{name}")

  describe "callgraph.dl via CLI.run" do
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

  describe "callgraph via Argus.analyze/2" do
    test "returns edges" do
      skip_without_souffle()

      assert {:ok, results} = Argus.analyze([Enum], :callgraph)
      assert Map.has_key?(results, "call_edge")
      edges = results["call_edge"]
      assert length(edges) > 0

      # Enum should call :lists functions.
      callee_strs = Enum.map(edges, fn [_caller, callee] -> callee end)
      assert Enum.any?(callee_strs, &String.contains?(&1, ":lists"))
    end

    test "multi-module callgraph" do
      skip_without_souffle()

      assert {:ok, results} = Argus.analyze([Enum, :lists], :callgraph)
      edges = results["call_edge"]
      callers = Enum.map(edges, fn [caller, _] -> caller end) |> Enum.uniq()

      # Should have callers from both modules.
      assert Enum.any?(callers, &String.starts_with?(&1, "Enum:"))
      assert Enum.any?(callers, &String.starts_with?(&1, ":lists:"))
    end
  end
end
