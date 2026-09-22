defmodule Argus.Analyses.BlockingCycleTest do
  use ExUnit.Case

  alias Argus.Souffle

  defp skip_without_souffle do
    unless Souffle.available?(), do: flunk("souffle not installed")
  end

  describe "call_cycle.dl" do
    test "detects mutual sync-call cycle between fixture GenServers" do
      skip_without_souffle()

      modules = [
        Argus.Test.Fixtures.CycleServerA,
        Argus.Test.Fixtures.CycleServerB
      ]

      assert {:ok, results} = Argus.analyze(modules, :blocking)
      assert Map.has_key?(results, "call_cycle")
      assert Map.has_key?(results, "call_cycle_path")

      cycles = results["call_cycle"]
      assert cycles != []

      # The two fixture modules should form a cycle.
      cycle_mods = cycles |> List.flatten() |> Enum.sort()

      assert "Argus.Test.Fixtures.CycleServerA" in cycle_mods
      assert "Argus.Test.Fixtures.CycleServerB" in cycle_mods
    end

    test "runs without error on module with no cycles" do
      skip_without_souffle()

      assert {:ok, results} = Argus.analyze([:maps], :blocking)
      assert Map.has_key?(results, "call_cycle")
    end

    test "detects gen_event sync_notify cycles via the gen_event extractor" do
      skip_without_souffle()

      # Two :gen_event handler modules whose handle_event clauses
      # sync_notify each other. With the gen_event extractor wired into
      # call_cycle's extractor list, the resulting sync_call facts feed
      # call_cycle's existing rules and the cycle is detected — the
      # whole point of reusing sync_call as the relation.
      modules = [
        Argus.Test.Fixtures.GenEventCycleA,
        Argus.Test.Fixtures.GenEventCycleB
      ]

      assert {:ok, results} = Argus.analyze(modules, :blocking)
      cycles = results["call_cycle"]
      assert cycles != []

      cycle_mods = cycles |> List.flatten() |> Enum.sort()
      assert "Argus.Test.Fixtures.GenEventCycleA" in cycle_mods
      assert "Argus.Test.Fixtures.GenEventCycleB" in cycle_mods
    end
  end
end
