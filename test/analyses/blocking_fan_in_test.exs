defmodule Argus.Analyses.BlockingFanInTest do
  use ExUnit.Case, async: true
  @moduletag :flowlog

  alias Argus.Test.Memo

  describe "process_bottleneck.dl" do
    test "below-threshold fan-in produces no findings" do
      # 3 modules with sync calls — below the >= 5 threshold.
      modules = [
        Argus.Test.Fixtures.CycleServerA,
        Argus.Test.Fixtures.CycleServerB,
        Argus.Test.Fixtures.MyGenServer
      ]

      assert {:ok, results} = Memo.analyze(modules, :blocking)
      assert Map.has_key?(results, "bottleneck_caller")
      assert Map.has_key?(results, "sync_call_fan_in")

      # Below threshold — no fan-in results.
      assert results["sync_call_fan_in"] == []
      assert results["bottleneck_caller"] == []
    end

    test "5 callers exceeds threshold" do
      modules = [
        Argus.Test.Fixtures.BottleneckTarget,
        Argus.Test.Fixtures.BottleneckCallerA,
        Argus.Test.Fixtures.BottleneckCallerB,
        Argus.Test.Fixtures.BottleneckCallerC,
        Argus.Test.Fixtures.BottleneckCallerD,
        Argus.Test.Fixtures.BottleneckCallerE
      ]

      assert {:ok, results} = Memo.analyze(modules, :blocking)

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
  end
end
