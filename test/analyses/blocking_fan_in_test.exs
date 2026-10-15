defmodule Argus.Analyses.BlockingFanInTest do
  use ExUnit.Case, async: true
  @moduletag :flowlog

  alias Argus.Test.Fixtures.FanIn
  alias Argus.Test.Memo

  @callers [FanIn.CallerA, FanIn.CallerB, FanIn.CallerC, FanIn.CallerD, FanIn.CallerE]

  # Every server beside the same five callers, in one solve: a shape
  # that silences its own server must not silence the others.
  @servers [
    FanIn.Hot,
    FanIn.CalledByName,
    FanIn.Patient,
    FanIn.MaybeNamed,
    FanIn.Instance,
    FanIn.PerKey,
    FanIn.Handoff,
    FanIn.DefersToItself,
    FanIn.HandsOffOneRequest,
    FanIn.Wrapped,
    FanIn.Facade
  ]

  setup_all do
    {:ok, results} = Memo.analyze(@servers ++ @callers, :blocking)

    fan_in =
      Map.new(results["sync_call_fan_in"], fn [server, count, waits] ->
        {String.replace_prefix(server, "Argus.Test.Fixtures.FanIn.", ""), {count, waits}}
      end)

    %{results: results, fan_in: fan_in}
  end

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

      assert [["Argus.Test.Fixtures.BottleneckTarget", "5", "bounded"]] =
               results["sync_call_fan_in"]

      # Raw rows carry one entry per witnessing function; finding
      # builders dedupe on (caller, target), so count distinct callers.
      callers = results["bottleneck_caller"]
      caller_mods = Enum.map(callers, fn [caller | _] -> caller end) |> Enum.uniq() |> Enum.sort()
      assert length(caller_mods) == 5

      assert "Argus.Test.Fixtures.BottleneckCallerA" in caller_mods
      assert "Argus.Test.Fixtures.BottleneckCallerE" in caller_mods
    end
  end

  describe "a bottleneck: one shared process five modules wait on directly" do
    test "a named server's client API, called from five modules", %{fan_in: fan_in} do
      assert fan_in["Hot"] == {"5", "bounded"}
    end

    test "GenServer.call by the registered name, from five modules", %{fan_in: fan_in} do
      assert fan_in["CalledByName"] == {"5", "bounded"}
    end

    test "a name the caller chooses may be the one every caller shares", %{fan_in: fan_in} do
      assert fan_in["MaybeNamed"] == {"5", "bounded"}
    end

    test "the callers are the modules making the calls", %{results: results} do
      callers =
        for [caller, "Argus.Test.Fixtures.FanIn.Hot", witness] <- results["bottleneck_caller"],
            do: {caller, witness}

      assert Enum.sort(callers) ==
               for(c <- @callers, do: {inspect(c), "#{inspect(c)}:hot/1"})
    end
  end

  describe "(a) callers count where they call the server" do
    test "callers reaching a server through one facade are one caller", %{fan_in: fan_in} do
      refute Map.has_key?(fan_in, "Wrapped")
    end
  end

  describe "(b) a process per start is no shared bottleneck" do
    test "an unnamed start, its pid handed to each caller", %{fan_in: fan_in} do
      refute Map.has_key?(fan_in, "Instance")
    end

    test "a name per key", %{fan_in: fan_in} do
      refute Map.has_key?(fan_in, "PerKey")
    end
  end

  describe "(c) a server handing its requests to processes of their own" do
    test "it defers every reply and starts the work elsewhere", %{fan_in: fan_in} do
      refute Map.has_key?(fan_in, "Handoff")
    end

    test "deferring to its own continuation still serializes", %{fan_in: fan_in} do
      assert fan_in["DefersToItself"] == {"5", "bounded"}
    end

    test "one request answered in the handler still serializes", %{fan_in: fan_in} do
      assert fan_in["HandsOffOneRequest"] == {"5", "bounded"}
    end
  end

  describe "(d) callers waiting with :infinity" do
    test "the fan-in says they wait rather than time out", %{fan_in: fan_in} do
      assert fan_in["Patient"] == {"5", "infinity"}
    end

    test "the finding drops the timeout consequence" do
      [patient] =
        Argus.Findings.build(Argus.Analyses.Blocking, %{
          "sync_call_fan_in" => [["Patient", "5", "infinity"]]
        })

      [hot] =
        Argus.Findings.build(Argus.Analyses.Blocking, %{
          "sync_call_fan_in" => [["Hot", "5", "bounded"]]
        })

      refute patient.detail =~ "timing out"
      assert patient.detail =~ ":infinity"
      assert hot.detail =~ "timing out"
    end
  end
end
