defmodule Argus.Analyses.ProcessBottleneckTest do
  use ExUnit.Case

  alias Argus.Souffle

  defp skip_without_souffle do
    unless Souffle.available?(), do: flunk("souffle not installed")
  end

  describe "process_bottleneck.dl" do
    test "below-threshold fan-in produces no findings" do
      skip_without_souffle()

      # 3 modules with sync calls — below the >= 5 threshold.
      modules = [
        Argus.Test.Fixtures.CycleServerA,
        Argus.Test.Fixtures.CycleServerB,
        Argus.Test.Fixtures.MyGenServer
      ]

      assert {:ok, results} = Argus.analyze(modules, :process_bottleneck)
      assert Map.has_key?(results, "bottleneck_caller")
      assert Map.has_key?(results, "sync_call_fan_in")

      # Below threshold — no fan-in results.
      assert results["sync_call_fan_in"] == []
      assert results["bottleneck_caller"] == []
    end

    test "5 callers exceeds threshold" do
      skip_without_souffle()

      modules = [
        Argus.Test.Fixtures.BottleneckTarget,
        Argus.Test.Fixtures.BottleneckCallerA,
        Argus.Test.Fixtures.BottleneckCallerB,
        Argus.Test.Fixtures.BottleneckCallerC,
        Argus.Test.Fixtures.BottleneckCallerD,
        Argus.Test.Fixtures.BottleneckCallerE
      ]

      assert {:ok, results} = Argus.analyze(modules, :process_bottleneck)

      fan_in = results["sync_call_fan_in"]
      assert length(fan_in) == 1

      assert Enum.any?(fan_in, fn [mod, cnt] ->
               mod == "Argus.Test.Fixtures.BottleneckTarget" and cnt == "5"
             end)

      # Raw rows carry one entry per witnessing function; finding
      # builders dedupe on (caller, target), so count distinct callers.
      callers = results["bottleneck_caller"]
      caller_mods = Enum.map(callers, fn [caller | _] -> caller end) |> Enum.uniq() |> Enum.sort()
      assert length(caller_mods) == 5

      assert "Argus.Test.Fixtures.BottleneckCallerA" in caller_mods
      assert "Argus.Test.Fixtures.BottleneckCallerE" in caller_mods
    end

    test "runs without error on modules with no sync calls" do
      skip_without_souffle()

      assert {:ok, results} = Argus.analyze([:maps], :process_bottleneck)
      assert Map.has_key?(results, "bottleneck_caller")
      assert Map.has_key?(results, "sync_call_fan_in")
    end
  end
end
