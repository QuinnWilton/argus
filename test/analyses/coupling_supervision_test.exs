defmodule Argus.Analyses.CouplingSupervisionTest do
  use ExUnit.Case, async: true

  alias Argus.Souffle
  alias Argus.Test.Fixtures.SupervisionShapes, as: Shapes
  alias Argus.Test.Memo

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

      assert {:ok, results} = Memo.analyze(modules, :coupling)

      rows =
        results["rest_for_one_orphaned_children"]
        |> Enum.map(fn [sup, owner, holder, opos, hpos, _site, conf] ->
          {sup, owner, holder, opos, hpos, conf}
        end)
        |> Enum.sort()

      assert rows == [
               {"Argus.Test.Fixtures.NamedQueueSupervisor",
                "Argus.Test.Fixtures.NamedJobProducer", "Task.Supervisor", "1", "0", "resolved"},
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
        # The anchor site is a relation separate from `supervisor`.
        supervisor_site: [["Sup", "Sup:init/1#3"]],
        supervisor_child: [
          ["Sup", "0", "P", "permanent", "worker"],
          ["Sup", "1", "S", sibling_restart, "worker"]
        ],
        # Map specs: the restart is the one they state.
        supervisor_child_form: [["Sup", "0", "explicit"], ["Sup", "1", "explicit"]],
        function_def: [["P:call_s/0", "P", "call_s", "0", "1", "1"]],
        sync_call: [["P:call_s/0", "S"]]
      }
    end

    test "flags a transient sibling dependency" do
      skip_without_souffle()

      assert [["Sup", "P", "S", "restart_policy", "transient", _site, _witness, _ | _]] =
               dependency_rows(base_facts("transient"))
    end

    test "flags a temporary sibling dependency" do
      skip_without_souffle()

      # Temporary is strictly worse than transient: never restarted,
      # not even after a crash.
      assert [["Sup", "P", "S", "restart_policy", "temporary", _site, _witness, _ | _]] =
               dependency_rows(base_facts("temporary"))
    end

    test "does not flag a permanent sibling dependency" do
      skip_without_souffle()

      # A permanent sibling is always restarted — the dependency is safe
      # from this rule's perspective.
      assert dependency_rows(base_facts("permanent")) == []
    end

    # Both children listed by the shorthand: `{P, arg}`, `{S, arg}`. The
    # extractor writes the default, :permanent, for each; the restart each
    # runs under is its module's own child_spec/1's when that states one.
    defp shorthand_facts(own_restarts) do
      %{
        base_facts("own")
        | supervisor_child: [
            ["Sup", "0", "P", "own", "worker"],
            ["Sup", "1", "S", "own", "worker"]
          ],
          supervisor_child_form: [["Sup", "0", "shorthand"], ["Sup", "1", "shorthand"]]
      }
      |> Map.put(:shorthand_arg, [["Sup", "P", "0", "options"], ["Sup", "S", "1", "options"]])
      |> Map.put(:child_spec_restart, own_restarts)
    end

    test "a shorthand sibling whose own child_spec/1 says :temporary is flagged" do
      skip_without_souffle()

      # `use GenServer, restart: :temporary` on S: the shorthand listing
      # it states nothing, and S is never restarted. P's own child_spec/1
      # states no restart (`use GenServer`): permanent, read as such.
      assert [["Sup", "P", "S", "restart_policy", "temporary", _site, _witness, _ | _]] =
               dependency_rows(shorthand_facts([["P", "permanent"], ["S", "temporary"]]))
    end

    test "a shorthand child whose own child_spec/1 says :temporary is not the permanent one" do
      skip_without_souffle()

      # P is temporary by its own child_spec/1: it stays down beside S
      # rather than running against a sibling that is gone.
      assert dependency_rows(shorthand_facts([["P", "temporary"], ["S", "temporary"]])) == []
      assert dependency_rows(shorthand_facts([])) == []
    end

    test "a shorthand child whose own restart is unread is neither permanent nor down" do
      skip_without_souffle()

      # Issue #4: a restart the extractor could not read is unknown, not
      # OTP's default: P is not shown permanent, and S not shown to stay
      # down.
      assert dependency_rows(shorthand_facts([["P", "dynamic"], ["S", "temporary"]])) == []
      assert dependency_rows(shorthand_facts([["S", "dynamic"]])) == []
    end

    test "a registration through a pid is anchored at the call that makes it" do
      skip_without_souffle()

      # P's init/1 makes two GenServer calls: #5 to a process nobody can
      # name, #9 to the S its supervisor starts, through the pid of the
      # name the child spec gives it, and S's handler keeps it as an ETS
      # row. The finding points at #9, not at whichever GenServer call of
      # P's came first. (An S that P started for itself would be P's own,
      # not the sibling.)
      facts =
        "transient"
        |> base_facts()
        |> Map.merge(%{
          function_def: [
            ["P:init/1", "P", "init", "1", "1"],
            ["S:handle_call/3", "S", "handle_call", "3", "1"]
          ],
          implements_behaviour: [["P", "GenServer"], ["S", "GenServer"]],
          supervisor_child_name: [["Sup", "1", "S"]],
          sync_call: [["P:init/1", "dynamic"]],
          call_site: [
            ["P:init/1#5", "P:init/1", "GenServer", "call", "2"],
            ["P:init/1#9", "P:init/1", "GenServer", "call", "2"]
          ],
          process_call_source: [["P:init/1#9", "P:init/1", "call", "name", "S"]],
          ets_op: [["S:handle_call/3#4", "S:handle_call/3", "subs", "insert", "write"]]
        })

      assert [["Sup", "P", "S", "restart_isolation", "table", _, "S:handle_call/3#4", site | _]] =
               dependency_rows(facts, "restart_isolation")

      assert site == "P:init/1#9"
    end

    test "a sibling used only in terminate/2 is not a dependency; one used at run time is" do
      skip_without_souffle()

      alias Argus.Test.Fixtures.TeardownDeps, as: T

      {:ok, r} = Memo.analyze([T.Sup, T.Keeper, T.Drainer, T.User], :coupling)

      children =
        for [_sup, child, sibling, "restart_policy", "transient" | _] <-
              Map.get(r, "sibling_dependency", []),
            uniq: true,
            do: {child, sibling}

      # Drainer reaches Keeper only from terminate/2, through a helper;
      # User reaches the same helper from handle_call/3 as well.
      assert children == [{inspect(T.User), inspect(T.Keeper)}]
    end

    defp dependency_rows(facts, reason \\ "restart_policy") do
      assert {:ok, results} = Argus.Test.Memo.run_rules(facts, :coupling)

      results
      |> Map.get("sibling_dependency", [])
      |> Enum.filter(&(Enum.at(&1, 3) == reason))
    end
  end

  describe "dual restart authority" do
    test "a manager that monitors and restarts a permanent dynamic child is reported" do
      skip_without_souffle()

      {:ok, r} =
        Memo.analyze(
          [
            Shapes.DualManager,
            Shapes.StatemDualManager,
            Shapes.TemporaryManager,
            Shapes.Conn,
            Shapes.TempConn
          ],
          :coupling
        )

      rows = Map.get(r, "dual_restart_authority", [])
      mods = rows |> Enum.map(&hd/1) |> Enum.uniq()

      assert mods == [
               "Argus.Test.Fixtures.SupervisionShapes.DualManager",
               "Argus.Test.Fixtures.SupervisionShapes.StatemDualManager"
             ]

      # The finding points at the start_child and the monitor, and names
      # the handler that starts the child again.
      for [mod, _sup, _child, _via, start_site, monitor_site, handler] <- rows do
        assert {:ok, _} = Argus.InstrId.parse(start_site)
        assert {:ok, _} = Argus.InstrId.parse(monitor_site)
        assert String.starts_with?(handler, mod <> ":")
      end
    end
  end
end
