defmodule Argus.Analyses.StartupContinueTest do
  use ExUnit.Case

  alias Argus.Souffle
  alias Argus.Test.Rows

  defp skip_without_souffle do
    unless Souffle.available?(), do: flunk("souffle not installed")
  end

  defp continue_to_later(results),
    do:
      Rows.where(results, :startup, "blocks_on_peer",
        phase: "continue",
        ordering: "later",
        drop: [:phase, :kind, :ordering, :site, :detail]
      )

  describe "blocks_on_peer: continue" do
    test "detects mutual handle_continue cycle (Pattern 1)" do
      skip_without_souffle()

      modules = [
        Argus.Test.Fixtures.ContinueCycleServerA,
        Argus.Test.Fixtures.ContinueCycleServerB,
        Argus.Test.Fixtures.ContinueCycleSupervisor
      ]

      # A continue cycle is blocking's call_cycle in the continue phase.
      assert {:ok, results} = Argus.analyze(modules, :blocking)
      cycles = Rows.where(results, :blocking, "call_cycle", phase: "continue")
      assert cycles != []

      # Cycle should pair the two cycle servers (lexicographic order from
      # the dedup constraint).
      assert Enum.any?(cycles, fn [a, b | _] ->
               a == "Argus.Test.Fixtures.ContinueCycleServerA" and
                 b == "Argus.Test.Fixtures.ContinueCycleServerB"
             end)
    end

    test "detects continue calling later-started sibling (Pattern 2)" do
      skip_without_souffle()

      modules = [
        Argus.Test.Fixtures.ContinueLateCallerServer,
        Argus.Test.Fixtures.ContinueLateTargetServer,
        Argus.Test.Fixtures.ContinueLateSiblingSupervisor
      ]

      assert {:ok, results} = Argus.analyze(modules, :startup)
      hits = continue_to_later(results)
      assert hits != []

      assert Enum.any?(hits, fn [caller, callee, sup] ->
               sup == "Argus.Test.Fixtures.ContinueLateSiblingSupervisor" and
                 caller == "Argus.Test.Fixtures.ContinueLateCallerServer" and
                 callee == "Argus.Test.Fixtures.ContinueLateTargetServer"
             end)
    end

    test "does NOT flag the safe sibling order (target started first)" do
      skip_without_souffle()

      modules = [
        Argus.Test.Fixtures.ContinueLateCallerServer,
        Argus.Test.Fixtures.ContinueLateTargetServer,
        Argus.Test.Fixtures.SafeContinueOrderSupervisor
      ]

      assert {:ok, results} = Argus.analyze(modules, :startup)

      # The unsafe supervisor isn't in the modules list, so the only
      # supervisor visible to the analysis is the safe one. No findings.
      assert continue_to_later(results) == []
    end

    test "does NOT flag external targets in disjoint supervision trees" do
      skip_without_souffle()

      modules = [
        Argus.Test.Fixtures.SafeContinueExternalCaller,
        Argus.Test.Fixtures.SafeContinueExternalTarget,
        Argus.Test.Fixtures.SafeContinueExternalCallerSupervisor,
        Argus.Test.Fixtures.SafeContinueExternalTargetSupervisor
      ]

      assert {:ok, results} = Argus.analyze(modules, :startup)
      assert continue_to_later(results) == []

      assert {:ok, blocking} = Argus.analyze(modules, :blocking)
      assert Rows.where(blocking, :blocking, "call_cycle", phase: "continue") == []
    end

    test "does NOT flag continue using cast (cast is async)" do
      skip_without_souffle()

      modules = [
        Argus.Test.Fixtures.SafeContinueCastCaller,
        Argus.Test.Fixtures.SafeContinueCastTarget,
        Argus.Test.Fixtures.SafeContinueCastSupervisor
      ]

      assert {:ok, results} = Argus.analyze(modules, :startup)
      assert continue_to_later(results) == []
    end

    test "flags defensive try/catch as a deferral defect" do
      skip_without_souffle()

      modules = [
        Argus.Test.Fixtures.DefensiveContinueCaller,
        Argus.Test.Fixtures.DefensiveContinueTarget,
        Argus.Test.Fixtures.DefensiveContinueSupervisor
      ]

      assert {:ok, results} = Argus.analyze(modules, :startup)

      # The defensive variant still triggers the literal pattern 2
      # (the call IS still there in the bytecode), and the crash-loop
      # finding fires on top.
      crash_loops = Rows.where(results, :startup, "deferral_defect", kind: "continue_catch")
      assert crash_loops != []

      assert Enum.any?(crash_loops, fn [worker | _] ->
               worker == "Argus.Test.Fixtures.DefensiveContinueCaller"
             end)
    end
  end

  describe "deferral_defect: init_timeout" do
    test "an init returning {:ok, state, 0} is reported; a {:continue, _} is not" do
      skip_without_souffle()

      assert {:ok, results} =
               Argus.analyze(
                 [
                   Argus.Test.Fixtures.TimeoutDeferredInit,
                   Argus.Test.Fixtures.ContinueDeferredInit
                 ],
                 :startup
               )

      assert [[mod, site, "0"]] =
               Rows.where(results, :startup, "deferral_defect",
                 kind: "init_timeout",
                 drop: [:kind]
               )

      assert mod == "Argus.Test.Fixtures.TimeoutDeferredInit"
      assert site =~ "TimeoutDeferredInit:init/1#"
    end
  end
end
