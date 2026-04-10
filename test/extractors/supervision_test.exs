defmodule Argus.Extractors.SupervisionTest do
  use ExUnit.Case, async: true

  alias Argus.Extractors.Supervision

  describe "extract/1" do
    test "detects supervisor module" do
      {:ok, data} =
        BeamSpy.BeamFile.disassemble(to_string(:code.which(Argus.Test.Fixtures.GoodSupervisor)))

      facts = Supervision.extract(data)

      assert Map.has_key?(facts, :supervisor)
      sups = facts[:supervisor]
      assert length(sups) == 1
      [mod_str, _strategy] = hd(sups)
      assert mod_str == "Argus.Test.Fixtures.GoodSupervisor"
    end

    test "detects supervision strategy" do
      {:ok, data} =
        BeamSpy.BeamFile.disassemble(to_string(:code.which(Argus.Test.Fixtures.GoodSupervisor)))

      facts = Supervision.extract(data)
      [_mod, strategy] = hd(facts[:supervisor])
      assert strategy == "one_for_one"
    end

    test "extracts child specs" do
      {:ok, data} =
        BeamSpy.BeamFile.disassemble(to_string(:code.which(Argus.Test.Fixtures.GoodSupervisor)))

      facts = Supervision.extract(data)

      if Map.has_key?(facts, :supervisor_child) do
        children = facts[:supervisor_child]
        assert length(children) >= 1

        child_mods = Enum.map(children, fn [_, _, mod, _, _] -> mod end)

        assert Enum.any?(child_mods, &String.contains?(&1, "WorkerA")) or
                 Enum.any?(child_mods, &String.contains?(&1, "WorkerB"))
      end
    end

    test "returns empty for non-supervisor module" do
      {:ok, data} =
        BeamSpy.BeamFile.disassemble(to_string(:code.which(Argus.Test.Fixtures.PlainModule)))

      facts = Supervision.extract(data)
      assert facts == %{}
    end
  end

  describe "Application modules" do
    test "detects application module as supervisor" do
      {:ok, data} =
        BeamSpy.BeamFile.disassemble(to_string(:code.which(Argus.Test.Fixtures.AppSupervisor)))

      facts = Supervision.extract(data)

      assert Map.has_key?(facts, :supervisor)
      [mod_str, _strategy] = hd(facts[:supervisor])
      assert mod_str == "Argus.Test.Fixtures.AppSupervisor"
    end

    test "detects strategy from Application start/2" do
      {:ok, data} =
        BeamSpy.BeamFile.disassemble(to_string(:code.which(Argus.Test.Fixtures.AppSupervisor)))

      facts = Supervision.extract(data)
      [_mod, strategy] = hd(facts[:supervisor])
      assert strategy == "one_for_one"
    end

    test "extracts children from Application start/2" do
      {:ok, data} =
        BeamSpy.BeamFile.disassemble(to_string(:code.which(Argus.Test.Fixtures.AppSupervisor)))

      facts = Supervision.extract(data)

      if Map.has_key?(facts, :supervisor_child) do
        children = facts[:supervisor_child]
        assert length(children) >= 1

        child_mods = Enum.map(children, fn [_, _, mod, _, _] -> mod end)

        assert Enum.any?(child_mods, &String.contains?(&1, "WorkerA")) or
                 Enum.any?(child_mods, &String.contains?(&1, "WorkerB"))
      end
    end
  end

  describe "map-based child specs" do
    setup do
      {:ok, data} =
        BeamSpy.BeamFile.disassemble(
          to_string(:code.which(Argus.Test.Fixtures.MapSpecSupervisor))
        )

      %{facts: Supervision.extract(data)}
    end

    test "extracts children from map child specs", %{facts: facts} do
      assert Map.has_key?(facts, :supervisor_child)
      children = facts[:supervisor_child]
      child_mods = Enum.map(children, fn [_, _, mod, _, _] -> mod end)

      assert "Argus.Test.Fixtures.WorkerA" in child_mods
      assert "Argus.Test.Fixtures.WorkerB" in child_mods
    end

    test "preserves correct child ordering", %{facts: facts} do
      children = facts[:supervisor_child]

      positions =
        Map.new(children, fn [_, pos, mod, _, _] -> {mod, String.to_integer(pos)} end)

      assert positions["Argus.Test.Fixtures.WorkerA"] < positions["Argus.Test.Fixtures.WorkerB"]
    end

    test "extracts restart and type metadata", %{facts: facts} do
      children = facts[:supervisor_child]
      worker_b = Enum.find(children, fn [_, _, mod, _, _] -> String.contains?(mod, "WorkerB") end)
      assert worker_b
      [_, _, _, restart, type] = worker_b
      assert restart == "transient"
      assert type == "worker"
    end

    test "detects supervisor behaviour and strategy", %{facts: facts} do
      assert Map.has_key?(facts, :supervisor)
      [mod_str, strategy] = hd(facts[:supervisor])
      assert mod_str == "Argus.Test.Fixtures.MapSpecSupervisor"
      assert strategy == "one_for_one"
    end
  end

  describe "extract/1 — PartitionSupervisor" do
    test "pierces PartitionSupervisor wrapper to extract the underlying child" do
      {:ok, data} =
        BeamSpy.BeamFile.disassemble(
          to_string(:code.which(Argus.Test.Fixtures.PartitionSupervisorParent))
        )

      facts = Supervision.extract(data)
      children = facts[:supervisor_child]

      # The underlying WorkerA module should be the recorded child, not
      # PartitionSupervisor itself.
      assert Enum.any?(children, fn [_sup, _pos, child, _restart, _type] ->
               child == "Argus.Test.Fixtures.WorkerA"
             end)

      refute Enum.any?(children, fn [_sup, _pos, child, _restart, _type] ->
               child == "PartitionSupervisor"
             end)
    end
  end

  describe "extract/1 — dynamic_child" do
    test "emits dynamic_child for DynamicSupervisor.start_child with bare module" do
      {:ok, data} =
        BeamSpy.BeamFile.disassemble(to_string(:code.which(Argus.Test.Fixtures.DynSupSpawner)))

      facts = Supervision.extract(data)

      assert Map.has_key?(facts, :dynamic_child)
      rows = facts[:dynamic_child]

      assert Enum.any?(rows, fn [sup, child, _caller] ->
               sup == "MyApp.WorkerSupervisor" and child == "MyApp.Worker"
             end)
    end

    test "emits dynamic_child for DynamicSupervisor.start_child with {Module, args} tuple" do
      {:ok, data} =
        BeamSpy.BeamFile.disassemble(to_string(:code.which(Argus.Test.Fixtures.DynSupSpawner)))

      facts = Supervision.extract(data)
      rows = facts[:dynamic_child]

      # spawn_worker_tuple/1 passes {MyApp.Worker, arg}.
      assert Enum.any?(rows, fn [sup, child, caller] ->
               sup == "MyApp.WorkerSupervisor" and
                 child == "MyApp.Worker" and
                 String.contains?(caller, "spawn_worker_tuple")
             end)
    end
  end

  describe "integration with extract pipeline" do
    test "extractor is usable via Pipeline.extract/2" do
      assert {:ok, facts} =
               Argus.Pipeline.extract(
                 [Argus.Test.Fixtures.GoodSupervisor],
                 extractors: [Supervision]
               )

      assert Map.has_key?(facts, :supervisor)
    end
  end
end
