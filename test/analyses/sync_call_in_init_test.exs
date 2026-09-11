defmodule Argus.Analyses.SyncCallInInitTest do
  use ExUnit.Case

  alias Argus.Souffle

  defp skip_without_souffle do
    unless Souffle.available?(), do: flunk("souffle not installed")
  end

  describe "sync_call_in_init.dl" do
    test "detects sync call in init/1 for fixture" do
      skip_without_souffle()

      modules = [
        Argus.Test.Fixtures.SyncInitServer,
        Argus.Test.Fixtures.WorkerA
      ]

      assert {:ok, results} = Argus.analyze(modules, :sync_call_in_init)
      assert Map.has_key?(results, "sync_call_in_init")

      init_calls = results["sync_call_in_init"]
      assert init_calls != []

      # SyncInitServer's init calls WorkerA on every init.
      assert Enum.any?(init_calls, fn [mod, _callee, kind] ->
               mod == "Argus.Test.Fixtures.SyncInitServer" and kind == "unconditional"
             end)
    end

    test "a call behind a branch in init is reported as conditional" do
      skip_without_souffle()

      modules = [
        Argus.Test.Fixtures.ConditionalInitServer,
        Argus.Test.Fixtures.SyncInitServer,
        Argus.Test.Fixtures.WorkerA
      ]

      assert {:ok, results} = Argus.analyze(modules, :sync_call_in_init)

      kinds =
        Map.new(results["sync_call_in_init"], fn [mod, _callee, kind] -> {mod, kind} end)

      assert kinds["Argus.Test.Fixtures.ConditionalInitServer"] == "conditional"
      assert kinds["Argus.Test.Fixtures.SyncInitServer"] == "unconditional"
    end

    test "filters safe sibling ordering (dep starts before caller)" do
      skip_without_souffle()

      modules = [
        Argus.Test.Fixtures.SafeOrderSupervisor,
        Argus.Test.Fixtures.SyncInitServer,
        Argus.Test.Fixtures.WorkerA
      ]

      assert {:ok, results} = Argus.analyze(modules, :sync_call_in_init)

      # WorkerA starts before SyncInitServer — safe, should be filtered.
      assert results["sync_call_in_init"] == []

      # The filtering relation should have the entry.
      assert results["init_safe_sibling"] != []
    end

    test "filters cross-supervisor calls (disjoint supervisor trees)" do
      skip_without_souffle()

      modules = [
        Argus.Test.Fixtures.DisjointSupervisor,
        Argus.Test.Fixtures.CallerSupervisor,
        Argus.Test.Fixtures.SyncInitServer,
        Argus.Test.Fixtures.WorkerA
      ]

      assert {:ok, results} = Argus.analyze(modules, :sync_call_in_init)

      # Disjoint supervisors — callee already running, should be filtered.
      assert results["sync_call_in_init"] == []

      assert results["init_safe_cross_supervisor"] != []
    end

    test "preserves deadlock risk when dep starts after caller" do
      skip_without_souffle()

      modules = [
        Argus.Test.Fixtures.DeadlockOrderSupervisor,
        Argus.Test.Fixtures.SyncInitServer,
        Argus.Test.Fixtures.WorkerA
      ]

      assert {:ok, results} = Argus.analyze(modules, :sync_call_in_init)

      # WorkerA starts AFTER SyncInitServer — NOT safe, deadlock risk.
      init_calls = results["sync_call_in_init"]
      assert init_calls != []

      assert Enum.any?(init_calls, fn [mod, callee, _kind] ->
               mod == "Argus.Test.Fixtures.SyncInitServer" and
                 callee == "Argus.Test.Fixtures.WorkerA"
             end)

      # init_deadlock_risk should detect this.
      deadlock_risks = results["init_deadlock_risk"]
      assert deadlock_risks != []

      assert Enum.any?(deadlock_risks, fn [sup, child, dep, _cpos, _dpos] ->
               sup == "Argus.Test.Fixtures.DeadlockOrderSupervisor" and
                 child == "Argus.Test.Fixtures.SyncInitServer" and
                 dep == "Argus.Test.Fixtures.WorkerA"
             end)
    end
  end
end
