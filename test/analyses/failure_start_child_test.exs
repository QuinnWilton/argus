defmodule Argus.Analyses.FailureStartChildTest do
  use ExUnit.Case, async: true

  alias Argus.Souffle
  alias Argus.Test.Memo
  alias Argus.Test.Rows

  defp skip_without_souffle do
    unless Souffle.available?(), do: flunk("souffle not installed")
  end

  describe "unchecked start_child" do
    test "detects unchecked start_child" do
      skip_without_souffle()

      assert {:ok, results} =
               Memo.analyze([Argus.Test.Fixtures.UncheckedStartChild], :failure)

      assert Map.has_key?(results, "unchecked_result")

      unchecked =
        Rows.where(results, :failure, "unchecked_result",
          api: "Task.Supervisor.start_child",
          drop: [:api, :name]
        )

      funcs = Enum.map(unchecked, fn [func, _id] -> func end)

      # start_unchecked ignores the result.
      assert Enum.any?(funcs, &String.contains?(&1, "start_unchecked"))

      # start_checked uses case on the result — should NOT be flagged.
      refute Enum.any?(funcs, &String.contains?(&1, "start_checked"))

      # start_tail is a tail call — result propagated, should NOT be flagged.
      refute Enum.any?(funcs, &String.contains?(&1, "start_tail"))

      # A branch later in the function, in another clause, does not run
      # after the start: the result is still dropped.
      assert Enum.any?(funcs, &String.contains?(&1, "start_then_other_clause"))

      # A match in the start's own clause runs after it.
      refute Enum.any?(funcs, &String.contains?(&1, "start_matched_in_clause"))
    end
  end
end
