defmodule Argus.Analyses.FailureSpawnTest do
  use ExUnit.Case, async: true
  @moduletag :souffle

  alias Argus.Test.Memo
  alias Argus.Test.Rows

  describe "failure.dl" do
    test "detects bare spawn calls in fixture" do
      assert {:ok, results} =
               Memo.analyze([Argus.Test.Fixtures.UnlinkedSpawner], :failure)

      assert Map.has_key?(results, "orphan_process")

      unlinked =
        Rows.where(results, :failure, "orphan_process",
          kind: "spawn",
          drop: [:kind, :target, :callback]
        )

      assert unlinked != []

      # Should only flag spawn, not spawn_link or spawn_monitor.
      funcs = Enum.map(unlinked, fn [func, _id] -> func end)

      assert Enum.any?(funcs, &String.contains?(&1, "spawn_unlinked"))
      refute Enum.any?(funcs, &String.contains?(&1, "spawn_linked"))
      refute Enum.any?(funcs, &String.contains?(&1, "spawn_monitored"))
      refute Enum.any?(funcs, &String.contains?(&1, "start_synchronously"))
    end

    test "a proc_lib:start whose worker loops after its ack is unwatched after it" do
      assert {:ok, results} = Memo.analyze([Argus.Test.Fixtures.ProcLibWorker], :failure)

      assert [[func, _id]] =
               Rows.where(results, :failure, "orphan_process",
                 kind: "start",
                 drop: [:kind, :target, :callback]
               )

      assert func =~ "ProcLibWorker:start_worker/0"
    end

    test "a spawn its caller monitors or links to afterwards is watched" do
      assert {:ok, results} =
               Memo.analyze([Argus.Test.Fixtures.ExitSignals.Watched], :failure)

      funcs =
        results
        |> Rows.where(:failure, "orphan_process",
          kind: "spawn",
          drop: [:kind, :target, :callback]
        )
        |> Enum.map(fn [func, _id] -> func end)

      assert Enum.any?(funcs, &String.contains?(&1, "Watched:unwatched/0"))
      refute Enum.any?(funcs, &String.contains?(&1, "Watched:monitored/0"))
      refute Enum.any?(funcs, &String.contains?(&1, "Watched:linked/0"))
    end

    test "spawns a closure makes are watched by a monitor or link on each pid, captured or not" do
      assert {:ok, results} = Memo.analyze([Argus.Test.Fixtures.SpawnsMapped], :failure)

      funcs =
        results
        |> Rows.where(:failure, "orphan_process",
          kind: "spawn",
          drop: [:kind, :target, :callback]
        )
        |> Enum.map(fn [func, _id] -> func end)

      assert Enum.any?(funcs, &String.contains?(&1, "unwatched_mapped/1"))

      for name <- ~w(monitored_capture/1 monitored_closure/1 linked_comprehension/1) do
        refute Enum.any?(funcs, &String.contains?(&1, name)), name
      end
    end
  end
end
