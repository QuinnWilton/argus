defmodule Argus.Clientlib.CallgraphRulesTest do
  use ExUnit.Case

  alias Argus.Pipeline
  alias Argus.Souffle

  @moduletag :tmp_dir

  defp skip_without_souffle do
    unless Souffle.available?(), do: flunk("souffle not installed")
  end

  defp priv_dl, do: Path.join(:code.priv_dir(:argus), "dl")

  describe "callgraph_rules.dl" do
    @tag :tmp_dir
    test "derives call_edge from remote, BIF, and local calls", %{tmp_dir: tmp_dir} do
      skip_without_souffle()

      facts_dir = Path.join(tmp_dir, "facts")
      {:ok, _} = Pipeline.run([Enum], facts_dir)

      # Write a custom .dl that includes the clientlib and outputs call_edge.
      rules = """
      .include "#{Path.join(priv_dl(), "clientlib/cfg.dl")}"

      .decl call_edge(caller: symbol, callee: symbol)
      .output call_edge
      .include "#{Path.join(priv_dl(), "clientlib/callgraph_rules.dl")}"
      """

      rules_path = Path.join(tmp_dir, "test_callgraph.dl")
      File.write!(rules_path, rules)

      assert {:ok, results} = Souffle.run(facts_dir, rules_path)
      assert Map.has_key?(results, "call_edge")

      edges = results["call_edge"]
      assert length(edges) > 0

      # Enum calls :lists functions (remote calls).
      callee_strs = Enum.map(edges, fn [_caller, callee] -> callee end)
      assert Enum.any?(callee_strs, &String.contains?(&1, ":lists"))

      # Should also contain :erlang BIF calls.
      assert Enum.any?(callee_strs, &String.contains?(&1, ":erlang"))
    end
  end
end
