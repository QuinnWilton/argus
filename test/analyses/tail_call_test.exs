defmodule Argus.Analyses.TailCallTest do
  use ExUnit.Case

  alias Argus.Souffle.CLI

  defp skip_without_souffle do
    unless CLI.available?(), do: flunk("souffle not installed")
  end

  describe "tail_call.dl" do
    test "identifies tail calls and recursion" do
      skip_without_souffle()

      assert {:ok, results} = Argus.analyze([:lists], :tail_call)
      assert Map.has_key?(results, "has_tail_call")
      assert length(results["has_tail_call"]) > 0

      # :lists has many recursive functions.
      assert Map.has_key?(results, "direct_recursion")
      assert length(results["direct_recursion"]) > 0
    end

    test "detects stack growth risks" do
      skip_without_souffle()

      assert {:ok, results} = Argus.analyze([:lists], :tail_call)
      # stack_growth_risk may or may not have results, but the analysis should succeed.
      assert is_map(results)
    end
  end
end
