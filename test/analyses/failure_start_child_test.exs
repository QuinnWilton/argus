defmodule Argus.Analyses.FailureStartChildTest do
  use ExUnit.Case

  alias Argus.Souffle

  defp skip_without_souffle do
    unless Souffle.available?(), do: flunk("souffle not installed")
  end

  describe "unchecked start_child" do
    test "detects unchecked start_child" do
      skip_without_souffle()

      assert {:ok, results} =
               Argus.analyze([Argus.Test.Fixtures.UncheckedStartChild], :failure)

      assert Map.has_key?(results, "unchecked_start_child")
      unchecked = results["unchecked_start_child"]

      funcs = Enum.map(unchecked, fn [func, _id] -> func end)

      # start_unchecked ignores the result.
      assert Enum.any?(funcs, &String.contains?(&1, "start_unchecked"))

      # start_checked uses case on the result — should NOT be flagged.
      refute Enum.any?(funcs, &String.contains?(&1, "start_checked"))

      # start_tail is a tail call — result propagated, should NOT be flagged.
      refute Enum.any?(funcs, &String.contains?(&1, "start_tail"))
    end
  end
end
