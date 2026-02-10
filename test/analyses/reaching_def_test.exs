defmodule Argus.Analyses.ReachingDefTest do
  use ExUnit.Case

  alias Argus.Souffle.CLI

  defp skip_without_souffle do
    unless CLI.available?(), do: flunk("souffle not installed")
  end

  describe "reaching_def.dl" do
    test "computes reaching definitions" do
      skip_without_souffle()

      assert {:ok, results} = Argus.analyze([:maps], :reaching_def)
      assert Map.has_key?(results, "reaching_def")
      assert Map.has_key?(results, "def_use")
      assert length(results["reaching_def"]) > 0
      assert length(results["def_use"]) > 0
    end
  end
end
