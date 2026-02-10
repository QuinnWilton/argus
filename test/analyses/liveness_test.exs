defmodule Argus.Analyses.LivenessTest do
  use ExUnit.Case

  alias Argus.Souffle.CLI

  defp skip_without_souffle do
    unless CLI.available?(), do: flunk("souffle not installed")
  end

  describe "liveness.dl" do
    test "computes live variables" do
      skip_without_souffle()

      assert {:ok, results} = Argus.analyze([:maps], :liveness)
      assert Map.has_key?(results, "live_in")
      assert Map.has_key?(results, "live_out")
      assert length(results["live_in"]) > 0
    end

    test "finds dead definitions" do
      skip_without_souffle()

      assert {:ok, results} = Argus.analyze([:maps], :liveness)
      # dead_def may or may not have entries depending on the module.
      assert Map.has_key?(results, "dead_def")
    end
  end
end
