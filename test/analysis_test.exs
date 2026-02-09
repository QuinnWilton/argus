defmodule Argus.AnalysisTest do
  use ExUnit.Case

  alias Argus.Souffle.CLI

  defp skip_without_souffle do
    unless CLI.available?(), do: flunk("souffle not installed")
  end

  describe "Argus.analyze/2" do
    test "cfg analysis returns non-empty edges" do
      skip_without_souffle()

      assert {:ok, results} = Argus.analyze([:lists], :cfg)
      assert Map.has_key?(results, "cfg_edge")
      assert length(results["cfg_edge"]) > 0
    end

    test "callgraph analysis returns edges" do
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

    test "reachability analysis" do
      skip_without_souffle()

      assert {:ok, results} = Argus.analyze([:maps], :reachability)
      assert Map.has_key?(results, "cfg_reachable")
      assert Map.has_key?(results, "call_reachable")
    end

    test "custom analysis with user rules" do
      skip_without_souffle()

      # Write a custom rule file.
      tmp = System.tmp_dir!()
      rules_path = Path.join(tmp, "argus_custom_test.dl")

      File.write!(rules_path, """
      .include "#{Path.join(:code.priv_dir(:argus), "dl/base.dl")}"

      .decl exported_function(func: symbol)
      .output exported_function

      exported_function(func) :- function_def(func, _, _, _, _, 1).
      """)

      assert {:ok, results} = Argus.analyze([:lists], {:custom, rules_path})
      assert Map.has_key?(results, "exported_function")
      assert length(results["exported_function"]) > 0
    end

    test "returns error for unknown analysis" do
      assert {:error, {:unknown_analysis, :nonexistent}} =
               Argus.analyze([:lists], :nonexistent)
    end

    test "returns error for non-existent module" do
      assert {:error, {:not_found, :fake_module_xyz}} =
               Argus.analyze([:fake_module_xyz], :cfg)
    end
  end

  describe "Analysis.builtin_analyses/0" do
    test "returns known analyses" do
      analyses = Argus.Analysis.builtin_analyses()
      assert :cfg in analyses
      assert :callgraph in analyses
      assert :reachability in analyses
    end
  end
end
