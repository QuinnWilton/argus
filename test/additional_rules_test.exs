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
  end

  describe "process_bottleneck.dl" do
    test "computes sync call fan-in" do
      skip_without_souffle()

      modules = [
        Argus.Test.Fixtures.CycleServerA,
        Argus.Test.Fixtures.CycleServerB,
        Argus.Test.Fixtures.MyGenServer
      ]

      assert {:ok, results} = Argus.analyze(modules, :process_bottleneck)
      assert Map.has_key?(results, "sync_caller")
      assert Map.has_key?(results, "sync_call_fan_in")
    end

    test "runs without error on modules with no sync calls" do
      skip_without_souffle()

      assert {:ok, results} = Argus.analyze([:maps], :process_bottleneck)
      assert Map.has_key?(results, "sync_caller")
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
    test "detects ETS ownership and access patterns" do
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

      assert Map.has_key?(results, "ets_owner_process")
      assert Map.has_key?(results, "ets_reader_module")
      assert Map.has_key?(results, "ets_writer_module")

      # EtsOwner creates a table, so there should be at least one owner entry.
      assert length(results["ets_owner_process"]) > 0
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
  end
end
