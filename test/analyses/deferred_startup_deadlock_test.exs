defmodule Argus.Analyses.DeferredStartupDeadlockTest do
  use ExUnit.Case

  alias Argus.Souffle

  defp skip_without_souffle do
    unless Souffle.available?(), do: flunk("souffle not installed")
  end

  describe "deferred_startup_deadlock.dl" do
    test "detects mutual handle_continue cycle (Pattern 1)" do
      skip_without_souffle()

      modules = [
        Argus.Test.Fixtures.ContinueCycleServerA,
        Argus.Test.Fixtures.ContinueCycleServerB,
        Argus.Test.Fixtures.ContinueCycleSupervisor
      ]

      assert {:ok, results} = Argus.analyze(modules, :deferred_startup_deadlock)
      cycles = results["mutual_continue_deadlock"]
      assert cycles != []

      # Cycle should pair the two cycle servers (lexicographic order from
      # the dedup constraint).
      assert Enum.any?(cycles, fn [a, b] ->
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

      assert {:ok, results} = Argus.analyze(modules, :deferred_startup_deadlock)
      hits = results["continue_to_later_sibling"]
      assert hits != []

      assert Enum.any?(hits, fn [sup, caller, callee, _, _] ->
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

      assert {:ok, results} = Argus.analyze(modules, :deferred_startup_deadlock)

      # The unsafe supervisor isn't in the modules list, so the only
      # supervisor visible to the analysis is the safe one. No findings.
      assert results["continue_to_later_sibling"] == []
    end

    test "does NOT flag external targets in disjoint supervision trees" do
      skip_without_souffle()

      modules = [
        Argus.Test.Fixtures.SafeContinueExternalCaller,
        Argus.Test.Fixtures.SafeContinueExternalTarget,
        Argus.Test.Fixtures.SafeContinueExternalCallerSupervisor,
        Argus.Test.Fixtures.SafeContinueExternalTargetSupervisor
      ]

      assert {:ok, results} = Argus.analyze(modules, :deferred_startup_deadlock)
      assert results["continue_to_later_sibling"] == []
      assert results["mutual_continue_deadlock"] == []
    end

    test "does NOT flag continue using cast (cast is async)" do
      skip_without_souffle()

      modules = [
        Argus.Test.Fixtures.SafeContinueCastCaller,
        Argus.Test.Fixtures.SafeContinueCastTarget,
        Argus.Test.Fixtures.SafeContinueCastSupervisor
      ]

      assert {:ok, results} = Argus.analyze(modules, :deferred_startup_deadlock)
      assert results["continue_to_later_sibling"] == []
    end

    test "flags defensive try/catch as continue_crash_loop_risk" do
      skip_without_souffle()

      modules = [
        Argus.Test.Fixtures.DefensiveContinueCaller,
        Argus.Test.Fixtures.DefensiveContinueTarget,
        Argus.Test.Fixtures.DefensiveContinueSupervisor
      ]

      assert {:ok, results} = Argus.analyze(modules, :deferred_startup_deadlock)

      # The defensive variant still triggers the literal pattern 2
      # (the call IS still there in the bytecode), and the crash-loop
      # finding fires on top.
      crash_loops = results["continue_crash_loop_risk"]
      assert crash_loops != []

      assert Enum.any?(crash_loops, fn [_sup, worker] ->
               worker == "Argus.Test.Fixtures.DefensiveContinueCaller"
             end)
    end
  end

  describe "init_timeout_deferral" do
    test "an init returning {:ok, state, 0} is reported; a {:continue, _} is not" do
      skip_without_souffle()

      assert {:ok, results} =
               Argus.analyze(
                 [
                   Argus.Test.Fixtures.TimeoutDeferredInit,
                   Argus.Test.Fixtures.ContinueDeferredInit
                 ],
                 :deferred_startup_deadlock
               )

      assert [[mod, site, "0"]] = results["init_timeout_deferral"]
      assert mod == "Argus.Test.Fixtures.TimeoutDeferredInit"
      assert site =~ "TimeoutDeferredInit:init/1#"
    end
  end
end
