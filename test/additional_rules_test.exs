defmodule Argus.AdditionalRulesTest do
  use ExUnit.Case

  alias Argus.Souffle.CLI

  defp skip_without_souffle do
    unless CLI.available?(), do: flunk("souffle not installed")
  end

  describe "reaching_def.dl" do
    test "computes reaching definitions" do
      skip_without_souffle()

      assert {:ok, results} = Argus.analyze([:maps], :reaching_def)
      assert Map.has_key?(results, "reaching_def")
      assert Map.has_key?(results, "def_use")
      assert length(results["reaching_def"]) > 0
      assert length(results["def_use"]) > 0
    end
  end

  describe "liveness.dl" do
    test "computes live variables" do
      skip_without_souffle()

      assert {:ok, results} = Argus.analyze([:maps], :liveness)
      assert Map.has_key?(results, "live_in")
      assert Map.has_key?(results, "live_out")
      assert length(results["live_in"]) > 0
    end

    test "finds dead definitions" do
      skip_without_souffle()

      assert {:ok, results} = Argus.analyze([:maps], :liveness)
      # dead_def may or may not have entries depending on the module.
      assert Map.has_key?(results, "dead_def")
    end
  end

  describe "tail_call.dl" do
    test "identifies tail calls and recursion" do
      skip_without_souffle()

      assert {:ok, results} = Argus.analyze([:lists], :tail_call)
      assert Map.has_key?(results, "has_tail_call")
      assert length(results["has_tail_call"]) > 0

      # :lists has many recursive functions.
      assert Map.has_key?(results, "direct_recursion")
      assert length(results["direct_recursion"]) > 0
    end

    test "detects stack growth risks" do
      skip_without_souffle()

      assert {:ok, results} = Argus.analyze([:lists], :tail_call)
      # stack_growth_risk may or may not have results, but the analysis should succeed.
      assert is_map(results)
    end
  end

  describe "message_flow.dl" do
    test "identifies sender and receiver functions" do
      skip_without_souffle()

      # :gen has actual receive instructions.
      assert {:ok, results} = Argus.analyze([:gen], :message_flow)

      assert Map.has_key?(results, "receiver_function")
      assert length(results["receiver_function"]) > 0
    end

    test "finds potential message paths" do
      skip_without_souffle()

      assert {:ok, results} = Argus.analyze([:gen], :message_flow)
      assert Map.has_key?(results, "potential_message_path")
    end
  end

  describe "call_cycle.dl" do
    test "detects mutual sync-call cycle between fixture GenServers" do
      skip_without_souffle()

      modules = [
        Argus.Test.Fixtures.CycleServerA,
        Argus.Test.Fixtures.CycleServerB
      ]

      assert {:ok, results} = Argus.analyze(modules, :call_cycle)
      assert Map.has_key?(results, "call_cycle")
      assert Map.has_key?(results, "call_cycle_path")

      cycles = results["call_cycle"]
      assert length(cycles) > 0

      # The two fixture modules should form a cycle.
      cycle_mods = cycles |> List.flatten() |> Enum.sort()

      assert "Argus.Test.Fixtures.CycleServerA" in cycle_mods
      assert "Argus.Test.Fixtures.CycleServerB" in cycle_mods
    end

    test "runs without error on module with no cycles" do
      skip_without_souffle()

      assert {:ok, results} = Argus.analyze([:maps], :call_cycle)
      assert Map.has_key?(results, "call_cycle")
    end
  end

  describe "unlinked_spawn.dl" do
    test "detects bare spawn calls in fixture" do
      skip_without_souffle()

      assert {:ok, results} =
               Argus.analyze([Argus.Test.Fixtures.UnlinkedSpawner], :unlinked_spawn)

      assert Map.has_key?(results, "unlinked_spawn")
      unlinked = results["unlinked_spawn"]
      assert length(unlinked) > 0

      # Should only flag spawn, not spawn_link or spawn_monitor.
      funcs = Enum.map(unlinked, fn [func, _id] -> func end)

      assert Enum.any?(funcs, &String.contains?(&1, "spawn_unlinked"))
      refute Enum.any?(funcs, &String.contains?(&1, "spawn_linked"))
      refute Enum.any?(funcs, &String.contains?(&1, "spawn_monitored"))
    end
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
      assert length(init_calls) > 0

      # SyncInitServer's init calls WorkerA.
      assert Enum.any?(init_calls, fn [mod, _callee] ->
               mod == "Argus.Test.Fixtures.SyncInitServer"
             end)
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
      assert length(results["init_safe_sibling"]) > 0
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

      assert length(results["init_safe_cross_supervisor"]) > 0
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
      assert length(init_calls) > 0

      assert Enum.any?(init_calls, fn [mod, callee] ->
               mod == "Argus.Test.Fixtures.SyncInitServer" and
                 callee == "Argus.Test.Fixtures.WorkerA"
             end)

      # init_deadlock_risk should detect this.
      deadlock_risks = results["init_deadlock_risk"]
      assert length(deadlock_risks) > 0

      assert Enum.any?(deadlock_risks, fn [sup, child, dep, _cpos, _dpos] ->
               sup == "Argus.Test.Fixtures.DeadlockOrderSupervisor" and
                 child == "Argus.Test.Fixtures.SyncInitServer" and
                 dep == "Argus.Test.Fixtures.WorkerA"
             end)
    end
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

      callers = results["bottleneck_caller"]
      assert length(callers) == 5

      caller_mods = Enum.map(callers, fn [caller, _target] -> caller end) |> Enum.sort()

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

  describe "supervision.dl" do
    test "analyzes supervisor fixtures" do
      skip_without_souffle()

      modules = [
        Argus.Test.Fixtures.GoodSupervisor,
        Argus.Test.Fixtures.BadOrderSupervisor,
        Argus.Test.Fixtures.WorkerA,
        Argus.Test.Fixtures.WorkerB
      ]

      assert {:ok, results} = Argus.analyze(modules, :supervision)

      assert Map.has_key?(results, "suspect_transient_dependency")
      assert Map.has_key?(results, "unlinked_coupled_siblings")
      assert Map.has_key?(results, "wrong_start_order")
    end
  end

  describe "ets.dl" do
    test "detects ETS anti-patterns" do
      skip_without_souffle()

      modules = [
        Argus.Test.Fixtures.EtsOwner,
        Argus.Test.Fixtures.EtsReader,
        Argus.Test.Fixtures.EtsWriter,
        Argus.Test.Fixtures.EtsUnnamed,
        Argus.Test.Fixtures.EtsWellConfigured,
        Argus.Test.Fixtures.EtsParamTable
      ]

      assert {:ok, results} = Argus.analyze(modules, :ets)

      # Informational relations are no longer output.
      refute Map.has_key?(results, "ets_owner_process")
      refute Map.has_key?(results, "ets_reader_module")
      refute Map.has_key?(results, "ets_writer_module")

      # EtsOwner without a supervisor still fires as unprotected.
      assert Map.has_key?(results, "ets_unprotected_owner")
      unprotected = results["ets_unprotected_owner"]

      assert Enum.any?(unprotected, fn [_name, mod] ->
               mod == "Argus.Test.Fixtures.EtsOwner"
             end)
    end

    test "suppresses unprotected_owner for permanent supervisor children" do
      skip_without_souffle()

      modules = [
        Argus.Test.Fixtures.EtsOwner,
        Argus.Test.Fixtures.EtsPermanentSupervisor
      ]

      assert {:ok, results} = Argus.analyze(modules, :ets)

      # EtsOwner is a permanent child — table recreated on restart.
      unprotected = results["ets_unprotected_owner"]

      refute Enum.any?(unprotected, fn [_name, mod] ->
               mod == "Argus.Test.Fixtures.EtsOwner"
             end)
    end

    test "EtsOwner without supervisor still fires unprotected_owner" do
      skip_without_souffle()

      modules = [Argus.Test.Fixtures.EtsOwner]

      assert {:ok, results} = Argus.analyze(modules, :ets)

      unprotected = results["ets_unprotected_owner"]

      assert Enum.any?(unprotected, fn [_name, mod] ->
               mod == "Argus.Test.Fixtures.EtsOwner"
             end)
    end
  end

  describe "one_for_one_coupling.dl" do
    test "analyzes coupling under one_for_one supervisors" do
      skip_without_souffle()

      modules = [
        Argus.Test.Fixtures.GoodSupervisor,
        Argus.Test.Fixtures.WorkerA,
        Argus.Test.Fixtures.WorkerB
      ]

      assert {:ok, results} = Argus.analyze(modules, :one_for_one_coupling)

      assert Map.has_key?(results, "one_for_one_coupling")
      assert Map.has_key?(results, "wrong_start_order")
    end

    test "wrong_start_order ignores runtime-only call paths" do
      skip_without_souffle()

      modules = [
        Argus.Test.Fixtures.RuntimeCallSupervisor,
        Argus.Test.Fixtures.RuntimeCallerWorker,
        Argus.Test.Fixtures.WorkerA
      ]

      assert {:ok, results} = Argus.analyze(modules, :one_for_one_coupling)

      # RuntimeCallerWorker calls WorkerA only from handle_call, not init.
      # wrong_start_order should be empty.
      assert results["wrong_start_order"] == []
    end
  end

  describe "unsafe_task.dl" do
    test "detects leaked async task" do
      skip_without_souffle()

      assert {:ok, results} =
               Argus.analyze([Argus.Test.Fixtures.LeakedTaskModule], :unsafe_task)

      assert Map.has_key?(results, "leaked_async_task")
      leaked = results["leaked_async_task"]
      assert length(leaked) > 0

      # fire_and_forget creates a task but never awaits.
      funcs = Enum.map(leaked, fn [func, _id] -> func end)
      assert Enum.any?(funcs, &String.contains?(&1, "fire_and_forget"))

      # safe_async awaits its task, so it should NOT be flagged.
      refute Enum.any?(funcs, &String.contains?(&1, "safe_async"))
    end

    test "suppresses leaked_async_task for GenServer with handle_info/2" do
      skip_without_souffle()

      modules = [
        Argus.Test.Fixtures.GenServerTaskConsumer,
        Argus.Test.Fixtures.LeakedTaskModule
      ]

      assert {:ok, results} = Argus.analyze(modules, :unsafe_task)

      leaked = results["leaked_async_task"]

      # GenServerTaskConsumer handles task results via handle_info — not leaked.
      refute Enum.any?(leaked, fn [func, _id] ->
               String.contains?(func, "GenServerTaskConsumer")
             end)

      # LeakedTaskModule.fire_and_forget is still flagged.
      assert Enum.any?(leaked, fn [func, _id] ->
               String.contains?(func, "fire_and_forget")
             end)
    end

    test "detects unchecked start_child" do
      skip_without_souffle()

      assert {:ok, results} =
               Argus.analyze([Argus.Test.Fixtures.UncheckedStartChild], :unsafe_task)

      assert Map.has_key?(results, "unchecked_start_child")
      unchecked = results["unchecked_start_child"]

      funcs = Enum.map(unchecked, fn [func, _id] -> func end)

      # start_unchecked ignores the result.
      assert Enum.any?(funcs, &String.contains?(&1, "start_unchecked"))

      # start_checked uses case on the result — should NOT be flagged.
      refute Enum.any?(funcs, &String.contains?(&1, "start_checked"))

      # start_tail is a tail call — result propagated, should NOT be flagged.
      refute Enum.any?(funcs, &String.contains?(&1, "start_tail"))
    end

    test "suppresses task factory (tail-position async)" do
      skip_without_souffle()

      modules = [
        Argus.Test.Fixtures.TaskFactory,
        Argus.Test.Fixtures.LeakedTaskModule
      ]

      assert {:ok, results} = Argus.analyze(modules, :unsafe_task)

      leaked = results["leaked_async_task"]

      # TaskFactory returns the task in tail position — not a leak.
      refute Enum.any?(leaked, fn [func, _id] ->
               String.contains?(func, "TaskFactory")
             end)

      # LeakedTaskModule.fire_and_forget is still flagged.
      assert Enum.any?(leaked, fn [func, _id] ->
               String.contains?(func, "fire_and_forget")
             end)
    end

    test "runs without error on modules with no task calls" do
      skip_without_souffle()

      assert {:ok, results} = Argus.analyze([:maps], :unsafe_task)
      assert Map.has_key?(results, "leaked_async_task")
      assert Map.has_key?(results, "unchecked_start_child")
    end
  end
end
