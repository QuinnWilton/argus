defmodule Argus.Analyses.CouplingSupervisionTest do
  use ExUnit.Case

  alias Argus.Souffle
  alias Argus.Test.Fixtures.SupervisionShapes, as: Shapes

  defp skip_without_souffle do
    unless Souffle.available?(), do: flunk("souffle not installed")
  end

  describe "rest_for_one_orphaned_children" do
    test "a later child starting tasks in an earlier Task.Supervisor is reported" do
      skip_without_souffle()

      modules = [
        Argus.Test.Fixtures.QueueSupervisor,
        Argus.Test.Fixtures.NamedQueueSupervisor,
        Argus.Test.Fixtures.AllForOneQueueSupervisor,
        Argus.Test.Fixtures.ForemanLastSupervisor,
        Argus.Test.Fixtures.JobProducer,
        Argus.Test.Fixtures.NamedJobProducer,
        Argus.Test.Fixtures.WorkerA
      ]

      assert {:ok, results} = Argus.analyze(modules, :coupling)

      rows =
        results["rest_for_one_orphaned_children"]
        |> Enum.map(fn [sup, owner, holder, opos, hpos, _site, conf] ->
          {sup, owner, holder, opos, hpos, conf}
        end)
        |> Enum.sort()

      assert rows == [
               {"Argus.Test.Fixtures.NamedQueueSupervisor",
                "Argus.Test.Fixtures.NamedJobProducer", "Task.Supervisor", "1", "0", "named"},
               {"Argus.Test.Fixtures.QueueSupervisor", "Argus.Test.Fixtures.JobProducer",
                "Task.Supervisor", "1", "0", "inferred"}
             ]
    end
  end

  describe "sibling_dependency: restart_policy" do
    # Hand-authored facts pin the rule exactly: P is a permanent child
    # that sync-calls its sibling S under the same supervisor. The
    # sibling's restart policy decides the verdict.
    defp base_facts(sibling_restart) do
      %{
        supervisor: [["Sup", "one_for_one"]],
        # Anchor site split out of `supervisor` in schema v8.
        supervisor_site: [["Sup", "Sup:init/1#3"]],
        supervisor_child: [
          ["Sup", "0", "P", "permanent", "worker"],
          ["Sup", "1", "S", sibling_restart, "worker"]
        ],
        function_def: [["P:call_s/0", "P", "call_s", "0", "1", "1"]],
        sync_call: [["P:call_s/0", "S"]]
      }
    end

    test "flags a transient sibling dependency" do
      skip_without_souffle()

      assert [["Sup", "P", "S", "restart_policy", "transient", _site, _witness, _]] =
               dependency_rows(base_facts("transient"))
    end

    test "flags a temporary sibling dependency" do
      skip_without_souffle()

      # Temporary is strictly worse than transient: never restarted,
      # not even after a crash.
      assert [["Sup", "P", "S", "restart_policy", "temporary", _site, _witness, _]] =
               dependency_rows(base_facts("temporary"))
    end

    test "does not flag a permanent sibling dependency" do
      skip_without_souffle()

      # A permanent sibling is always restarted — the dependency is safe
      # from this rule's perspective.
      assert dependency_rows(base_facts("permanent")) == []
    end

    defp dependency_rows(facts) do
      dir =
        Path.join(
          System.tmp_dir!(),
          "coupling_test_#{:erlang.unique_integer([:positive])}"
        )

      File.mkdir_p!(dir)

      try do
        :ok = Argus.Pipeline.write_facts(facts, dir)
        assert {:ok, results} = Argus.Analysis.run_rules(dir, :coupling)

        results
        |> Map.get("sibling_dependency", [])
        |> Enum.filter(&(Enum.at(&1, 3) == "restart_policy"))
      after
        File.rm_rf(dir)
      end
    end
  end

  describe "dual restart authority" do
    test "a manager that monitors and restarts a permanent dynamic child is reported" do
      skip_without_souffle()

      {:ok, r} =
        Argus.analyze(
          [
            Shapes.DualManager,
            Shapes.StatemDualManager,
            Shapes.TemporaryManager,
            Shapes.Conn,
            Shapes.TempConn
          ],
          :coupling
        )

      mods = Enum.map(Map.get(r, "dual_restart_authority", []), &hd/1) |> Enum.uniq()

      assert mods == [
               "Argus.Test.Fixtures.SupervisionShapes.DualManager",
               "Argus.Test.Fixtures.SupervisionShapes.StatemDualManager"
             ]
    end
  end
end
