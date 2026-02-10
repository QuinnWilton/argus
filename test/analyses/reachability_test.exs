defmodule Argus.Analyses.ReachabilityTest do
  use ExUnit.Case

  alias Argus.Extract
  alias Argus.Souffle.CLI

  @moduletag :tmp_dir

  defp skip_without_souffle do
    unless CLI.available?(), do: flunk("souffle not installed")
  end

  defp priv_dl(name), do: Path.join(:code.priv_dir(:argus), "dl/#{name}")

  describe "reachability.dl via CLI.run" do
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

  describe "reachability via Argus.analyze/2" do
    test "returns reachability relations" do
      skip_without_souffle()

      assert {:ok, results} = Argus.analyze([:maps], :reachability)
      assert Map.has_key?(results, "cfg_reachable")
      assert Map.has_key?(results, "call_reachable")
    end
  end
end
