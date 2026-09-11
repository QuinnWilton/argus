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

    test "supervisor management calls from init are reported" do
      skip_without_souffle()

      assert {:ok, results} =
               Argus.analyze([Argus.Test.Fixtures.StartsChildrenInInit], :sync_call_in_init)

      assert [[mod, "DynamicSupervisor", "start_child", "Argus.Test.Fixtures.PoolSup", site]] =
               results["sup_call_in_init"]

      assert mod == "Argus.Test.Fixtures.StartsChildrenInInit"
      assert site =~ "StartsChildrenInInit:"
    end

    test "a call the tree-order argument accepts is still reported when the callee's handler blocks" do
      skip_without_souffle()

      modules = [
        Argus.Test.Fixtures.WatcherAppTree,
        Argus.Test.Fixtures.BlockingWatcher,
        Argus.Test.Fixtures.WatchedPool
      ]

      assert {:ok, results} = Argus.analyze(modules, :sync_call_in_init)

      # The Watcher is in the app tree and the pool is not: the plain
      # finding is (correctly) suppressed as a cross-supervisor call...
      assert ["Argus.Test.Fixtures.WatchedPool", "Argus.Test.Fixtures.BlockingWatcher"] in results[
               "init_safe_cross_supervisor"
             ]

      refute Enum.any?(results["sync_call_in_init"], fn [mod, _, _] ->
               mod == "Argus.Test.Fixtures.WatchedPool"
             end)

      # ...and the blocking handler is what makes it a finding anyway.
      assert [[mod, dep, handler, op_site]] = results["init_waits_on_blocking_server"]
      assert mod == "Argus.Test.Fixtures.WatchedPool"
      assert dep == "Argus.Test.Fixtures.BlockingWatcher"
      assert handler =~ "BlockingWatcher:handle_info/2"
      assert op_site =~ "BlockingWatcher:handle_info/2#"
    end

    test "a handler that only starts children is bounded and not reported" do
      skip_without_souffle()

      modules = [
        Argus.Test.Fixtures.StarterAppTree,
        Argus.Test.Fixtures.StartingWatcher,
        Argus.Test.Fixtures.WatchedByStarter
      ]

      assert {:ok, results} = Argus.analyze(modules, :sync_call_in_init)

      assert results["init_waits_on_blocking_server"] == []
    end

    test "a sibling started earlier by a GenServer-defined tree is safe" do
      skip_without_souffle()

      # The Broadway shape: the tree lives in a GenServer's init/1, the
      # producer's init calls the rate limiter, and the rate limiter is an
      # earlier child of the same rest_for_one supervisor.
      modules = [
        Argus.Test.Fixtures.TopologyServer,
        Argus.Test.Fixtures.SyncInitServer,
        Argus.Test.Fixtures.WorkerA
      ]

      assert {:ok, results} = Argus.analyze(modules, :sync_call_in_init)

      assert ["Argus.Test.Fixtures.SyncInitServer", "Argus.Test.Fixtures.WorkerA"] in results[
               "init_safe_sibling"
             ]

      refute Enum.any?(results["sync_call_in_init"], fn [mod, _, _] ->
               mod == "Argus.Test.Fixtures.SyncInitServer"
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
