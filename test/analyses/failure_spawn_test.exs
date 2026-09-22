defmodule Argus.Analyses.FailureSpawnTest do
  use ExUnit.Case

  alias Argus.Souffle
  alias Argus.Test.Rows

  defp skip_without_souffle do
    unless Souffle.available?(), do: flunk("souffle not installed")
  end

  describe "failure.dl" do
    test "detects bare spawn calls in fixture" do
      skip_without_souffle()

      assert {:ok, results} =
               Argus.analyze([Argus.Test.Fixtures.UnlinkedSpawner], :failure)

      assert Map.has_key?(results, "orphan_process")

      unlinked =
        Rows.where(results, :failure, "orphan_process", kind: "spawn", drop: [:kind, :target])

      assert unlinked != []

      # Should only flag spawn, not spawn_link or spawn_monitor.
      funcs = Enum.map(unlinked, fn [func, _id] -> func end)

      assert Enum.any?(funcs, &String.contains?(&1, "spawn_unlinked"))
      refute Enum.any?(funcs, &String.contains?(&1, "spawn_linked"))
      refute Enum.any?(funcs, &String.contains?(&1, "spawn_monitored"))
    end
  end
end
