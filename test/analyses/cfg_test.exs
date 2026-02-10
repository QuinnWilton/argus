defmodule Argus.Analyses.CfgTest do
  use ExUnit.Case

  alias Argus.Extract
  alias Argus.Souffle.CLI

  @moduletag :tmp_dir

  defp skip_without_souffle do
    unless CLI.available?(), do: flunk("souffle not installed")
  end

  defp priv_dl(name), do: Path.join(:code.priv_dir(:argus), "dl/#{name}")

  describe "cfg.dl via CLI.run" do
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

  describe "cfg via Argus.analyze/2" do
    test "returns non-empty edges" do
      skip_without_souffle()

      assert {:ok, results} = Argus.analyze([:lists], :cfg)
      assert Map.has_key?(results, "cfg_edge")
      assert length(results["cfg_edge"]) > 0
    end
  end
end
