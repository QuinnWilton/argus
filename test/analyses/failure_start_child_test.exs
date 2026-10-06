defmodule Argus.Analyses.FailureStartChildTest do
  use ExUnit.Case, async: true
  @moduletag :souffle

  alias Argus.Test.Memo
  alias Argus.Test.Rows

  describe "unchecked start_child" do
    test "detects unchecked start_child" do
      assert {:ok, results} =
               Memo.analyze([Argus.Test.Fixtures.UncheckedStartChild], :failure)

      assert Map.has_key?(results, "unchecked_result")

      unchecked =
        Rows.where(results, :failure, "unchecked_result",
          api: "Task.Supervisor.start_child",
          drop: [:api, :name]
        )

      funcs = Enum.map(unchecked, fn [func, _id] -> func end)

      # start_unchecked ignores the result.
      assert Enum.any?(funcs, &String.contains?(&1, "start_unchecked"))

      # start_checked uses case on the result — should NOT be flagged.
      refute Enum.any?(funcs, &String.contains?(&1, "start_checked"))

      # start_tail is a tail call — result propagated, should NOT be flagged.
      refute Enum.any?(funcs, &String.contains?(&1, "start_tail"))

      # A branch later in the function, in another clause, does not run
      # after the start: the result is still dropped.
      assert Enum.any?(funcs, &String.contains?(&1, "start_then_other_clause"))

      # A match in the start's own clause runs after it.
      refute Enum.any?(funcs, &String.contains?(&1, "start_matched_in_clause"))
    end
  end

  describe "a start that cannot fail" do
    alias Argus.Test.Fixtures.TaskCaps

    defp unchecked_funcs(modules) do
      {:ok, results} = Memo.analyze(modules, :failure)

      results
      |> Rows.where(:failure, "unchecked_result",
        api: "Task.Supervisor.start_child",
        drop: [:api, :name]
      )
      |> Enum.map(fn [func, _id] -> func end)
      |> Enum.sort()
    end

    test "only a start whose supervisor may have a cap is reported" do
      # A literal cap, a cap the extractor cannot read, a capped partition
      # and a pid (which may be BoundedSup) are reported; a supervisor with
      # no max_children, and a partition of them, answer only {:ok, pid}.
      assert unchecked_funcs([TaskCaps.App, TaskCaps.Starter]) ==
               Enum.map(
                 ~w(to_bounded/0 to_capped_partition/0 to_pid/1 to_sized/0),
                 &"#{inspect(TaskCaps.Starter)}:#{&1}"
               )
    end

    test "a supervisor the start does not name is uncapped when none in view is capped" do
      # livebook's RuntimeServer: `Task.Supervisor.start_link()` kept in the
      # state, and a name the program does not start.
      assert unchecked_funcs([TaskCaps.RuntimeServer, TaskCaps.App]) ==
               [
                 "#{inspect(TaskCaps.RuntimeServer)}:handle_cast/2",
                 "#{inspect(TaskCaps.RuntimeServer)}:to_elsewhere/0"
               ]

      assert unchecked_funcs([TaskCaps.RuntimeServer]) == []
    end
  end
end
