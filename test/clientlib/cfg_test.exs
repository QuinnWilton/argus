defmodule Argus.Clientlib.CfgTest do
  use ExUnit.Case

  alias Argus.Pipeline
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
      {:ok, _} = Pipeline.run([:maps], facts_dir)

      # cfg.dl deliberately does not `.output cfg_edge` — forcing it out
      # makes every consumer materialize a relation nothing reads. Ask for
      # it explicitly here, the way an analysis that wanted it would.
      rules_path = Path.join(tmp_dir, "cfg_probe.dl")

      File.write!(rules_path, """
      .include "#{clientlib_path("cfg.dl")}"
      .output cfg_edge
      """)

      assert {:ok, results} = Souffle.run(facts_dir, rules_path)

      assert Map.has_key?(results, "cfg_edge")
      edges = results["cfg_edge"]
      assert edges != []

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
