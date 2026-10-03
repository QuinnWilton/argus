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
      # The anchor site is a separate relation.
      [_smod, site] = hd(facts[:supervisor_site])
      assert strategy == "one_for_one"

      # The site names the instruction that defines the tree, inside init/1.
      assert site =~ ~r/^Argus\.Test\.Fixtures\.GoodSupervisor:init\/1#\d+$/
    end

    test "reads the strategy of a flags tuple built at run time" do
      {:ok, data} = BeamSpy.BeamFile.disassemble(to_string(:code.which(:flags_runtime_sup)))
      facts = Supervision.extract(data)

      assert [":flags_runtime_sup", "one_for_all"] in facts[:supervisor]
    end

    test "extracts child specs" do
      {:ok, data} =
        BeamSpy.BeamFile.disassemble(to_string(:code.which(Argus.Test.Fixtures.GoodSupervisor)))

      facts = Supervision.extract(data)

      if Map.has_key?(facts, :supervisor_child) do
        children = facts[:supervisor_child]
        assert children != []

        child_mods = Enum.map(children, fn [_, _, mod, _, _] -> mod end)

        assert Enum.any?(child_mods, &String.contains?(&1, "WorkerA")) or
                 Enum.any?(child_mods, &String.contains?(&1, "WorkerB"))
      end
    end

    test "reads a supervisor that declares no behaviour and starts itself as one" do
      {:ok, data} = BeamSpy.BeamFile.disassemble(to_string(:code.which(:bless_bare_sup)))
      facts = Supervision.extract(data)

      assert [":bless_bare_sup", "one_for_one"] in facts[:supervisor]

      assert facts[:supervisor_child] |> Enum.map(&Enum.at(&1, 2)) |> Enum.sort() ==
               [":bless_callee", ":bless_caller"]
    end

    test "returns empty for non-supervisor module" do
      {:ok, data} =
        BeamSpy.BeamFile.disassemble(to_string(:code.which(Argus.Test.Fixtures.PlainModule)))

      facts = Supervision.extract(data)
      assert facts == %{}
    end
  end

  describe "trees defined outside Supervisor modules" do
    test "a GenServer starting a supervisor from helpers and a comprehension" do
      {:ok, facts} =
        Argus.Pipeline.extract([Argus.Test.Fixtures.TopologyServer],
          extractors: [Argus.Extractors.Supervision]
        )

      # The runtime-built option list still yields the strategy.
      assert [["Argus.Test.Fixtures.TopologyServer", "rest_for_one"]] = facts[:supervisor]

      children =
        facts[:supervisor_child]
        |> Enum.sort_by(fn [_sup, pos | _] -> String.to_integer(pos) end)
        |> Enum.map(fn [_sup, _pos, mod | _] -> mod end)

      # The spec from a called helper comes before the one from the
      # comprehension closure that helper's sibling creates — the
      # construction order the source expresses.
      assert children == ["Argus.Test.Fixtures.WorkerA", "Argus.Test.Fixtures.SyncInitServer"]
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
      # The anchor site is a separate relation.
      [_smod, site] = hd(facts[:supervisor_site])
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
        assert children != []

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

  describe "extract/1 — task_supervisor_start" do
    test "each Task.Supervisor start says which call made it, and the supervisor it names" do
      starts = fn mod ->
        {:ok, data} = BeamSpy.BeamFile.disassemble(to_string(:code.which(mod)))

        for [_id, func, op, sup] <-
              Map.get(Supervision.extract(data), :task_supervisor_start, []),
            do: {func |> String.split(":") |> List.last(), op, sup}
      end

      assert starts.(Argus.Test.Fixtures.UnboundedChildren.TaskLive) == [
               {"handle_event/3", "start_child",
                inspect(Argus.Test.Fixtures.UnboundedChildren.TaskSup)}
             ]

      assert [{"handle_event/3", "async_stream_nolink", _sup}] =
               starts.(Argus.Test.Fixtures.UnboundedChildren.StreamLive)

      alias Argus.Test.Fixtures.TaskCaps

      # A PartitionSupervisor's via names the partition; a pid names none.
      assert Enum.sort(starts.(TaskCaps.Starter)) == [
               {"to_bounded/0", "start_child", inspect(TaskCaps.BoundedSup)},
               {"to_capped_partition/0", "start_child", inspect(TaskCaps.CappedPartitions)},
               {"to_open/0", "start_child", inspect(TaskCaps.OpenSup)},
               {"to_partition/0", "start_child", inspect(TaskCaps.Partitions)},
               {"to_pid/1", "start_child", "dynamic"},
               {"to_sized/0", "start_child", inspect(TaskCaps.SizedSup)}
             ]
    end
  end

  describe "extract/1 — task_supervisor_cap" do
    alias Argus.Test.Fixtures.TaskCaps

    defp caps(mod) do
      {:ok, data} = BeamSpy.BeamFile.disassemble(to_string(:code.which(mod)))
      data |> Supervision.extract() |> Map.get(:task_supervisor_cap, []) |> Enum.sort()
    end

    test "every Task.Supervisor a module starts, with its name and its max_children" do
      # A literal cap, none, one from a call (unreadable), and the
      # partitions of a PartitionSupervisor under its name.
      assert caps(TaskCaps.App) == [
               [inspect(TaskCaps.BoundedSup), "10"],
               [inspect(TaskCaps.CappedPartitions), "2"],
               [inspect(TaskCaps.OpenSup), "infinity"],
               [inspect(TaskCaps.Partitions), "infinity"],
               [inspect(TaskCaps.SizedSup), "dynamic"]
             ]

      # start_link/0 names none and states no cap.
      assert caps(TaskCaps.RuntimeServer) == [["dynamic", "infinity"]]
      assert caps(Argus.Test.Fixtures.UncheckedStartChild) == [["dynamic", "5"]]
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

      assert [mod, strategy] = hd(facts[:supervisor])
      assert [_smod, site] = hd(facts[:supervisor_site])
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

    test "another module's helper is not resolved through a local one of the same name" do
      {:ok, data} =
        BeamSpy.BeamFile.disassemble(to_string(:code.which(Argus.Test.Fixtures.ViaImpostor)))

      assert [["dynamic", "Argus.Test.Fixtures.ViaQueueSup", _caller]] =
               Map.get(Supervision.extract(data), :dynamic_child, [])
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

  describe "OTP tuple child specs" do
    setup do
      {:ok, data} = BeamSpy.BeamFile.disassemble(to_string(:code.which(:tuple_spec_sup)))
      %{facts: Supervision.extract(data)}
    end

    # init/1's three clauses compile into one function, so the children of
    # all three are read as one tree, in the order the bytecode lists them;
    # the assertions ask which children each spec shape yields.
    test "a literal, a runtime-built and a wrapped spec each yield their child", %{facts: facts} do
      children =
        for [":tuple_spec_sup", _pos, child, restart, type] <- facts[:supervisor_child],
            do: {child, restart, type}

      # The literal list's callback modules; a `dynamic` modules list
      # names the start function's module; the runtime-built spec's
      # computed argument hides nothing its child is known by.
      assert {":tuple_spec_first", "permanent", "worker"} in children
      assert {":tuple_spec_pool_sup", "permanent", "supervisor"} in children
      assert {":tuple_spec_buffer", "permanent", "worker"} in children
      assert Enum.any?(children, &match?({":tuple_spec_last", _, "worker"}, &1))

      # A start through the supervisor's own wrapper is not the wrapper's
      # child: the modules list names the child, and a list the bytecode
      # cannot show (worker_spec/1's parameter) names none.
      refute Enum.any?(children, &match?({":tuple_spec_sup", _, _}, &1))
    end

    test "the stated type makes the form explicit", %{facts: facts} do
      forms = for [":tuple_spec_sup", _pos, form] <- facts[:supervisor_child_form], do: form
      assert forms != [] and Enum.all?(forms, &(&1 == "explicit"))
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

  describe "a child module chosen by Keyword.get/3 with a literal default" do
    test "the default is the child, and later siblings keep their positions" do
      {:ok, data} =
        BeamSpy.BeamFile.disassemble(
          to_string(:code.which(Argus.Test.Fixtures.ConfigurableQueueSupervisor))
        )

      children =
        Supervision.extract(data)[:supervisor_child]
        |> Enum.map(fn [_sup, pos, mod, _restart, _type] -> {pos, mod} end)
        |> Enum.sort()

      assert children == [
               {"0", "Task.Supervisor"},
               {"1", "Argus.Test.Fixtures.DefaultProducer"},
               {"2", "Argus.Test.Fixtures.WorkerA"}
             ]
    end
  end

  describe "extract/1 — the child list, read in order" do
    alias Argus.Test.Soundness.Startup, as: S

    defp children(mod) do
      {:ok, data} = BeamSpy.BeamFile.disassemble(to_string(:code.which(mod)))
      facts = Supervision.extract(data)

      rows =
        for [_sup, pos, child | _] <- Map.get(facts, :supervisor_child, []),
            do: {String.to_integer(pos), child}

      {rows |> Enum.sort() |> Enum.map(&elem(&1, 1)),
       Map.has_key?(facts, :supervisor_children_open)}
    end

    test "a Supervisor.child_spec/2 element is its spec's child, in its place" do
      assert children(S.ContSpec.Sup) ==
               {[inspect(S.ContSpec.Worker), inspect(S.ContSpec.Later)], false}

      assert children(S.ContLast.Sup) ==
               {[inspect(S.ContLast.Earlier), inspect(S.ContLast.Worker)], false}
    end

    test "a list the extractor cannot read to its end is open" do
      assert children(S.ContConfig.Sup) == {[inspect(S.ContConfig.Worker)], true}
      assert children(S.ContHelper.Sup) == {[inspect(S.ContHelper.Worker)], true}
      assert {_, true} = children(S.ContMapped.Sup)
    end
  end

  describe "extract/1 — specs beyond a literal list (the ETS rows round)" do
    alias Argus.Test.Fixtures.ChildSpecs, as: Specs

    defp facts_of(mod) do
      {:ok, data} = BeamSpy.BeamFile.disassemble(to_string(:code.which(mod)))
      Supervision.extract(data)
    end

    # `{children in position order as {child, restart, type}, open?}`.
    defp tree(mod) do
      facts = facts_of(mod)

      rows =
        for [_sup, pos, child, restart, type] <- Map.get(facts, :supervisor_child, []),
            do: {String.to_integer(pos), {child, restart, type}}

      {rows |> Enum.sort() |> Enum.map(&elem(&1, 1)),
       Map.has_key?(facts, :supervisor_children_open)}
    end

    test "a helper's tuple spec is read with its parameters bound to the call's arguments" do
      # worker/1, worker_spec/3 (modules `[Name] ++ Modules`), supervisor/1
      # through supervisor/2, and restart_spec/2 handed `temporary`; the
      # module configured_owner/0 returns from a call names no child, and
      # the list is open.
      assert tree(:spec_helper_sup) ==
               {[
                  {inspect(Specs.HelperOwner), "permanent", "worker"},
                  {inspect(Specs.ModulesOwner), "permanent", "worker"},
                  {":spec_helper_child_sup", "permanent", "supervisor"},
                  {inspect(Specs.HelperTempOwner), "temporary", "worker"},
                  {":spec_helper_last", "permanent", "worker"},
                  {":spec_helper_restarted", "permanent", "worker"},
                  {":spec_helper_other_sup", "permanent", "supervisor"}
                ], true}
    end

    test "a list joined with ++ is its parts' children, in order, open where a part is unread" do
      # A conditional helper's child is a child (on the path that starts
      # it); Specs.Remote.children/0 is another module's list.
      {children, open?} = tree(Specs.AppendedApp)

      assert Enum.map(children, &elem(&1, 0)) ==
               ["Registry", inspect(Specs.OptionalOwner), inspect(Specs.AppendedOwner)] ++
                 [inspect(Specs.MapOwner)]

      assert open?
    end

    test "Enum.reject(&is_nil/1) keeps a list closed; another predicate opens it" do
      # Shorthands: their restart is their own child_spec/1's (`own`).
      assert tree(Specs.RejectSup) ==
               {[
                  {inspect(Specs.RejectedOwner), "own", "worker"},
                  {"Registry", "own", "worker"}
                ], false}

      assert {_children, true} = tree(Specs.PredicateSup)
    end

    test "an override's restart, a map's default and a restart from a call" do
      assert tree(Specs.OverrideSup) ==
               {[
                  {inspect(Specs.OverriddenOwner), "temporary", "worker"},
                  {inspect(Specs.OverriddenPermanentOwner), "temporary", "worker"},
                  {inspect(Specs.RuntimeMapOwner), "permanent", "worker"},
                  {inspect(Specs.RuntimeRestartOwner), "dynamic", "worker"}
                ], false}
    end

    test "a helper handed a name keeps each child's registered name" do
      facts = facts_of(Specs.NamedPoolsApp)

      names =
        for [_sup, pos, name] <- facts[:supervisor_child_name], do: {pos, name}

      assert Enum.sort(names) == [
               {"0", inspect(Specs.FirstPool)},
               {"1", inspect(Specs.SecondPool)}
             ]

      refute Map.has_key?(facts, :supervisor_children_open)
    end
  end

  describe "extract/1 — a child a start_child adds" do
    alias Argus.Test.Fixtures.ChildSpecs, as: Specs

    defp added(mod) do
      {:ok, data} = BeamSpy.BeamFile.disassemble(to_string(:code.which(mod)))
      facts = Supervision.extract(data)
      {facts |> Map.get(:added_child, []) |> Enum.sort(), Map.get(facts, :dynamic_child, [])}
    end

    test "supervisor:start_child/2's spec is read with its restart and type" do
      # dets_server's ensure_started/0 shape: a tuple spec, a map spec with
      # no restart (permanent), a temporary one, one whose restart comes
      # from a call. A spec whose module is the function's parameter and a
      # simple_one_for_one template's argument list name no child.
      {added, []} = added(:spec_start_child)

      assert added == [
               [
                 ":kernel_safe_sup",
                 inspect(Specs.AddedDynOwner),
                 "dynamic",
                 "worker",
                 ":spec_start_child:ensure_restart/0"
               ],
               [
                 ":kernel_safe_sup",
                 inspect(Specs.AddedMapOwner),
                 "permanent",
                 "worker",
                 ":spec_start_child:ensure_map/0"
               ],
               [
                 ":kernel_safe_sup",
                 inspect(Specs.AddedOwner),
                 "permanent",
                 "worker",
                 ":spec_start_child:ensure/0"
               ],
               [
                 ":kernel_safe_sup",
                 inspect(Specs.AddedTempOwner),
                 "temporary",
                 "worker",
                 ":spec_start_child:ensure_temp/0"
               ]
             ]
    end

    test "Supervisor.start_child/2 adds its spec's child; a shorthand's restart is its own child_spec/1's" do
      {added, dynamic} = added(Specs.Starter)

      assert added == [
               [
                 inspect(Specs.Supervisor),
                 inspect(Specs.StartedOwner),
                 "own",
                 "worker",
                 "#{inspect(Specs.Starter)}:start_permanent/0"
               ],
               [
                 inspect(Specs.Supervisor),
                 inspect(Specs.StartedShorthandTempOwner),
                 "own",
                 "worker",
                 "#{inspect(Specs.Starter)}:start_shorthand_temporary/0"
               ],
               [
                 inspect(Specs.Supervisor),
                 inspect(Specs.StartedTempOwner),
                 "temporary",
                 "worker",
                 "#{inspect(Specs.Starter)}:start_temporary/1"
               ]
             ]

      assert Enum.sort(dynamic) == [
               [
                 inspect(Specs.Pool),
                 inspect(Specs.DynamicOwner),
                 "#{inspect(Specs.Starter)}:start_dynamic/1"
               ],
               [
                 inspect(Specs.Pool),
                 inspect(Specs.DynamicOwner),
                 "#{inspect(Specs.Starter)}:start_dynamic_temporary/1"
               ]
             ]
    end

    test "a DynamicSupervisor start's own spec states the restart it overrides" do
      {:ok, data} = BeamSpy.BeamFile.disassemble(to_string(:code.which(Specs.Starter)))

      # The Supervisor.child_spec/2 override's :temporary, and no row for
      # the start whose spec is the child's own child_spec/1.
      assert Supervision.extract(data)[:dynamic_child_restart] == [
               [
                 inspect(Specs.Pool),
                 inspect(Specs.DynamicOwner),
                 "#{inspect(Specs.Starter)}:start_dynamic_temporary/1",
                 "temporary"
               ]
             ]
    end
  end

  describe "extract/1 — the type a module's own child_spec/1 states" do
    alias Argus.Test.Fixtures.ChildSpecs, as: Specs

    defp own_type(mod) do
      {:ok, data} = BeamSpy.BeamFile.disassemble(to_string(:code.which(mod)))

      for [_mod, type] <- Map.get(Supervision.extract(data), :child_spec_type, []), do: type
    end

    test "a map with no :type is a worker; use Supervisor's and a stated type are not" do
      assert own_type(Specs.TenantSup) == ["worker"]
      assert own_type(Specs.TypelessWorker) == ["worker"]
      assert own_type(Specs.TypedTenantSup) == ["supervisor"]
      assert own_type(Specs.SuperTenantSup) == ["supervisor"]
      assert own_type(Specs.PoolSup) == ["supervisor"]
    end

    test "a map spec in a child list states its type: a worker by default" do
      {:ok, data} =
        BeamSpy.BeamFile.disassemble(to_string(:code.which(Specs.TypelessSup)))

      forms =
        for [_sup, pos, form] <- Supervision.extract(data)[:supervisor_child_form],
            do: {pos, form}

      assert Enum.sort(forms) == [{"0", "explicit"}, {"1", "explicit"}]
    end
  end

  describe "extract/1 — what a shorthand hands its child_spec/1 (issue #4)" do
    alias Argus.Test.Fixtures.Issue4

    defp issue4(mod) do
      {:ok, data} = BeamSpy.BeamFile.disassemble(to_string(:code.which(mod)))
      Supervision.extract(data)
    end

    test "a restart read off the argument is an option with its default, not a restart row" do
      facts = issue4(Issue4.Repro.Worker)

      assert facts[:child_spec_option] == [
               [inspect(Issue4.Repro.Worker), "restart", "restart", "transient"]
             ]

      refute Map.has_key?(facts, :child_spec_restart)
    end

    test "a map that states no restart is permanent; one the reader cannot read is dynamic" do
      assert issue4(Issue4.Stoppers.NoRestartKey)[:child_spec_restart] == [
               [inspect(Issue4.Stoppers.NoRestartKey), "permanent"]
             ]

      assert issue4(Issue4.Stoppers.UnreadRestart)[:child_spec_restart] == [
               [inspect(Issue4.Stoppers.UnreadRestart), "dynamic"]
             ]
    end

    test "each shorthand start records its argument's options" do
      facts = issue4(Issue4.Starter)
      at = fn fun -> inspect(Issue4.Starter) <> ":" <> fun end

      args = for [_sup, _child, where, shape] <- facts[:shorthand_arg], do: {where, shape}
      assert {at.("overridden/0"), "options"} in args
      assert {at.("handed/1"), "dynamic"} in args

      options =
        for [_sup, _child, where, key, value] <- facts[:shorthand_option], do: {where, key, value}

      assert {at.("overridden/0"), "restart", "permanent"} in options
      assert {at.("defaulted/1"), "name", "dynamic"} in options
    end

    test "a shorthand of a behaviour's own module is a dynamic child of that module" do
      facts = issue4(Argus.Test.Fixtures.ChildSpecs.TaskStarter)
      assert [[_sup, "Task", _via]] = facts[:dynamic_child]
    end

    test "a shorthand in a child list is `own`, with its argument's options at its position" do
      facts = issue4(Issue4.ListSup)

      assert Enum.sort(
               for [_, pos, _, restart, _] <- facts[:supervisor_child], do: {pos, restart}
             ) ==
               [{"0", "own"}, {"1", "own"}]

      assert Enum.sort(
               for [_, _, pos, key, value] <- facts[:shorthand_option], do: {pos, key, value}
             ) ==
               [{"0", "restart", "permanent"}, {"1", "restart", "transient"}]
    end
  end
end
