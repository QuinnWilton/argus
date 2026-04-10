defmodule Argus.Clientlib.CallReachableRulesTest do
  use ExUnit.Case

  alias Argus.Pipeline
  alias Argus.Souffle

  @moduletag :tmp_dir

  defp skip_without_souffle do
    unless Souffle.available?(), do: flunk("souffle not installed")
  end

  defp priv_dl, do: Path.join(:code.priv_dir(:argus), "dl")

  describe "call_reachable_rules.dl" do
    @tag :tmp_dir
    test "computes transitive call reachability", %{tmp_dir: tmp_dir} do
      skip_without_souffle()

      facts_dir = Path.join(tmp_dir, "facts")
      {:ok, _} = Pipeline.run([Enum, :lists], facts_dir)

      # Use imports.dl which bundles cfg + callgraph + call_reachable.
      rules = """
      .include "#{Path.join(priv_dl(), "clientlib/imports.dl")}"
      .output call_reachable
      """

      rules_path = Path.join(tmp_dir, "test_reachable.dl")
      File.write!(rules_path, rules)

      assert {:ok, results} = Souffle.run(facts_dir, rules_path)
      assert Map.has_key?(results, "call_reachable")

      reachable = results["call_reachable"]
      assert length(reachable) > 0

      # Enum functions should transitively reach :erlang functions
      # (Enum -> :lists -> :erlang).
      assert Enum.any?(reachable, fn [from, to] ->
               String.starts_with?(from, "Enum:") and
                 String.contains?(to, ":erlang")
             end)
    end
  end
end
