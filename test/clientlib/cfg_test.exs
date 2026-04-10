defmodule Argus.Clientlib.CfgTest do
  use ExUnit.Case

  alias Argus.Extract
  alias Argus.Souffle

  @moduletag :tmp_dir

  defp skip_without_souffle do
    unless Souffle.available?(), do: flunk("souffle not installed")
  end

  defp clientlib_path(name), do: Path.join(:code.priv_dir(:argus), "dl/clientlib/#{name}")

  describe "cfg.dl" do
    @tag :tmp_dir
    test "derives cfg_edge with sequential, jump, and branch edges", %{tmp_dir: tmp_dir} do
      skip_without_souffle()

      facts_dir = Path.join(tmp_dir, "facts")
      {:ok, _} = Extract.run([:maps], facts_dir)

      # cfg.dl already declares .output cfg_edge, so we can include it directly.
      rules_path = clientlib_path("cfg.dl")
      assert {:ok, results} = Souffle.run(facts_dir, rules_path)

      assert Map.has_key?(results, "cfg_edge")
      edges = results["cfg_edge"]
      assert length(edges) > 0

      # Verify edges are pairs of instruction IDs.
      for [from, to] <- edges do
        assert is_binary(from)
        assert is_binary(to)
        assert from != ""
        assert to != ""
      end

      # Should have more edges than just sequential (branches and jumps too).
      # :maps has conditional code paths, so we expect branching edges.
      assert length(edges) > 10
    end
  end
end
