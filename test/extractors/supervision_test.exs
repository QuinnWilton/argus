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
      [mod_str, _strategy, _site] = hd(sups)
      assert mod_str == "Argus.Test.Fixtures.GoodSupervisor"
    end

    test "detects supervision strategy" do
      {:ok, data} =
        BeamSpy.BeamFile.disassemble(to_string(:code.which(Argus.Test.Fixtures.GoodSupervisor)))

      facts = Supervision.extract(data)
      [_mod, strategy, site] = hd(facts[:supervisor])
      assert strategy == "one_for_one"

      # The site names the instruction that defines the tree, inside init/1.
      assert site =~ ~r/^Argus\.Test\.Fixtures\.GoodSupervisor:init\/1#\d+$/
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
      [mod_str, _strategy, _site] = hd(facts[:supervisor])
      assert mod_str == "Argus.Test.Fixtures.AppSupervisor"
    end

    test "detects strategy from Application start/2" do
      {:ok, data} =
        BeamSpy.BeamFile.disassemble(to_string(:code.which(Argus.Test.Fixtures.AppSupervisor)))

      facts = Supervision.extract(data)
      [_mod, strategy, site] = hd(facts[:supervisor])
      assert strategy == "one_for_one"

      # Application trees are wired in start/2, not init/1.
      assert site =~ ~r/^Argus\.Test\.Fixtures\.AppSupervisor:start\/2#\d+$/
    end

    test "recovers children from a cons-built list with a runtime element" do
      {:ok, data} =
        BeamSpy.BeamFile.disassemble(to_string(:code.which(Argus.Test.Fixtures.MixedChildrenApp)))

      facts = Supervision.extract(data)

      children =
        facts
        |> Map.get(:supervisor_child, [])
        |> Enum.map(fn [_sup, _pos, child, _restart, _type] -> child end)
        |> Enum.sort()

      # Every member is recovered: the bare cons head, the literal tail,
      # and the runtime-built tuple's module (unloaded modules included —
      # the analyzed project's deps are never loadable in this VM).
      assert children == [
               "Argus.Test.Fixtures.GoodSupervisor",
               "Argus.Test.Fixtures.RuntimeCallerWorker",
               "Argus.Test.Fixtures.WorkerA",
               "Argus.Test.Fixtures.WorkerB"
             ]
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
      [mod_str, strategy, _site] = hd(facts[:supervisor])
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

  describe "extract/1 — registered child names" do
    test "records the :name option from a child spec alongside its position" do
      {:ok, data} =
        BeamSpy.BeamFile.disassemble(to_string(:code.which(Argus.Test.Fixtures.MixedChildrenApp)))

      facts = Supervision.extract(data)

      # {WorkerB, name: :mixed_b} — the name rides at WorkerB's position.
      names = Map.get(facts, :supervisor_child_name, [])
      assert [_sup, pos, ":mixed_b"] = Enum.find(names, fn [_, _, n] -> n == ":mixed_b" end)

      child_at_pos =
        Enum.find(facts[:supervisor_child], fn [_, p, _, _, _] -> p == pos end)

      assert [_, ^pos, "Argus.Test.Fixtures.WorkerB", _, _] = child_at_pos
    end

    test "keeps same-module children distinct when they register different names" do
      {:ok, data} =
        BeamSpy.BeamFile.disassemble(
          to_string(:code.which(Argus.Test.Fixtures.NamedPoolSupervisor))
        )

      facts = Supervision.extract(data)

      # Both DynamicSupervisor children survive dedup — collapsing by module
      # alone would have dropped one.
      dyn_children =
        Enum.filter(facts[:supervisor_child], fn [_, _, mod, _, _] ->
          mod == "DynamicSupervisor"
        end)

      assert length(dyn_children) == 2

      names =
        facts |> Map.get(:supervisor_child_name, []) |> Enum.map(&List.last/1) |> Enum.sort()

      assert names == ["Argus.Test.Fixtures.PoolA", "Argus.Test.Fixtures.PoolB"]
    end
  end

  describe "extract/1 — DynamicSupervisor behaviour" do
    test "records a `use DynamicSupervisor` module as a supervisor" do
      {:ok, data} =
        BeamSpy.BeamFile.disassemble(
          to_string(:code.which(Argus.Test.Fixtures.SelfAnchoringDynSup))
        )

      facts = Supervision.extract(data)

      assert [mod, strategy, site] = hd(facts[:supervisor])
      assert mod == "Argus.Test.Fixtures.SelfAnchoringDynSup"
      assert strategy == "one_for_one"
      assert site =~ ~r/^Argus\.Test\.Fixtures\.SelfAnchoringDynSup:init\/1#\d+$/

      # A DynamicSupervisor has no static child specs.
      refute Map.has_key?(facts, :supervisor_child)
    end

    test "anchors an unresolved start_child to the enclosing supervisor module" do
      {:ok, data} =
        BeamSpy.BeamFile.disassemble(
          to_string(:code.which(Argus.Test.Fixtures.SelfAnchoringDynSup))
        )

      facts = Supervision.extract(data)

      assert Enum.any?(facts[:dynamic_child], fn [sup, child, _caller] ->
               sup == "Argus.Test.Fixtures.SelfAnchoringDynSup" and
                 child == "Argus.Test.Fixtures.WorkerA"
             end)
    end

    test "leaves an unresolved start_child in a non-supervisor module as \"dynamic\"" do
      {:ok, data} =
        BeamSpy.BeamFile.disassemble(to_string(:code.which(Argus.Test.Fixtures.DynSupSpawner)))

      facts = Supervision.extract(data)

      # spawn_via_arg/1 passes a runtime sup from a plain module — no self to
      # anchor to, so the parent stays "dynamic".
      assert Enum.any?(facts[:dynamic_child], fn [sup, child, caller] ->
               sup == "dynamic" and child == "MyApp.Worker" and
                 String.contains?(caller, "spawn_via_arg")
             end)
    end
  end

  describe "extract/1 — via-tuple (Registry) registration names" do
    test "records a DynamicSupervisor child's via role as its registered name" do
      {:ok, data} =
        BeamSpy.BeamFile.disassemble(to_string(:code.which(Argus.Test.Fixtures.ViaNursery)))

      facts = Supervision.extract(data)

      names = Map.get(facts, :supervisor_child_name, [])

      # The DynamicSupervisor registers under Registry.via(_, Foreman); the
      # runtime registry name is dropped, the role is kept.
      assert Enum.any?(names, fn [_sup, _pos, name] ->
               name =~ ~r/\.via\(Foreman\)$/
             end)
    end

    test "resolves a start_child via-target through a local helper to the same name" do
      {:ok, data} =
        BeamSpy.BeamFile.disassemble(to_string(:code.which(Argus.Test.Fixtures.ViaMidwife)))

      facts = Supervision.extract(data)

      # The Foreman via name here must equal the one ViaNursery registered,
      # so the two anchor together downstream.
      assert [[sup, "Argus.Test.Fixtures.ViaQueueSup", _caller]] =
               Map.get(facts, :dynamic_child, [])

      assert sup =~ ~r/\.via\(Foreman\)$/
      refute sup == "dynamic"
    end

    test "the registration and start_child sides produce identical via names" do
      {:ok, nursery} =
        BeamSpy.BeamFile.disassemble(to_string(:code.which(Argus.Test.Fixtures.ViaNursery)))

      {:ok, midwife} =
        BeamSpy.BeamFile.disassemble(to_string(:code.which(Argus.Test.Fixtures.ViaMidwife)))

      foreman_name =
        Supervision.extract(nursery)
        |> Map.fetch!(:supervisor_child_name)
        |> Enum.find_value(fn [_, _, name] -> if name =~ ~r/Foreman/, do: name end)

      [[start_child_sup | _]] = Map.fetch!(Supervision.extract(midwife), :dynamic_child)

      # Identical strings → anchoring matches; Midwife's own via role
      # (Midwife) is a different name, so it never mis-anchors.
      assert foreman_name == start_child_sup
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
