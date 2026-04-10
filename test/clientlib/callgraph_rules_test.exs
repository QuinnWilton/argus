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

    @tag :tmp_dir
    test "follows closures lifted by the compiler into call_edge", %{tmp_dir: tmp_dir} do
      skip_without_souffle()

      facts_dir = Path.join(tmp_dir, "facts")
      {:ok, _} = Pipeline.run([Argus.Test.Fixtures.ClosureModule], facts_dir)

      rules = """
      .include "#{Path.join(priv_dl(), "clientlib/cfg.dl")}"

      .decl call_edge(caller: symbol, callee: symbol)
      .output call_edge
      .include "#{Path.join(priv_dl(), "clientlib/callgraph_rules.dl")}"
      """

      rules_path = Path.join(tmp_dir, "test_closure_callgraph.dl")
      File.write!(rules_path, rules)

      assert {:ok, results} = Souffle.run(facts_dir, rules_path)
      edges = results["call_edge"]

      # spans_telemetry/1 builds a closure pointing at a lifted body whose
      # function name starts with "-spans_telemetry/1-". The closure_def fact
      # gets derived into a call_edge by the rule we just added.
      parent = "Argus.Test.Fixtures.ClosureModule:spans_telemetry/1"

      assert Enum.any?(edges, fn [caller, callee] ->
               caller == parent and String.contains?(callee, "-spans_telemetry/1-")
             end),
             "expected closure_def-derived edge from #{parent} to its lifted body, " <>
               "got: #{inspect(Enum.filter(edges, fn [c, _] -> c == parent end))}"

      # Same shape for the Enum.map closure.
      maps_parent = "Argus.Test.Fixtures.ClosureModule:maps_through_enum/1"

      assert Enum.any?(edges, fn [caller, callee] ->
               caller == maps_parent and String.contains?(callee, "-maps_through_enum/1-")
             end)
    end
  end
end
