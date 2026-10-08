defmodule Argus.Analyses.MailboxTaskTest do
  use ExUnit.Case, async: true
  @moduletag :flowlog

  alias Argus.Test.Memo
  alias Argus.Test.Rows

  defp tasks(results, kind),
    do: Rows.where(results, :mailbox, "task_result_defect", kind: kind, drop: [:kind])

  defp leaked(results), do: tasks(results, "never_awaited")

  describe "task_result_defect: never_awaited" do
    test "detects leaked async task" do
      assert {:ok, results} =
               Memo.analyze([Argus.Test.Fixtures.LeakedTaskModule], :mailbox)

      assert Map.has_key?(results, "task_result_defect")
      leaked = leaked(results)
      assert leaked != []

      # fire_and_forget creates a task but never awaits.
      funcs = Enum.map(leaked, fn [func, _id] -> func end)
      assert Enum.any?(funcs, &String.contains?(&1, "fire_and_forget"))

      # safe_async awaits its task, so it should NOT be flagged.
      refute Enum.any?(funcs, &String.contains?(&1, "safe_async"))
    end

    test "suppresses leaked_async_task for GenServer with handle_info/2" do
      modules = [
        Argus.Test.Fixtures.GenServerTaskConsumer,
        Argus.Test.Fixtures.LeakedTaskModule
      ]

      assert {:ok, results} = Memo.analyze(modules, :mailbox)

      leaked = leaked(results)

      # GenServerTaskConsumer handles task results via handle_info — not leaked.
      refute Enum.any?(leaked, fn [func, _id] ->
               String.contains?(func, "GenServerTaskConsumer")
             end)

      # LeakedTaskModule.fire_and_forget is still flagged.
      assert Enum.any?(leaked, fn [func, _id] ->
               String.contains?(func, "fire_and_forget")
             end)
    end

    test "suppresses leaked_async_task for any module defining handle_info/2" do
      modules = [
        Argus.Test.Fixtures.PlainTaskConsumer,
        Argus.Test.Fixtures.LeakedTaskModule
      ]

      assert {:ok, results} = Memo.analyze(modules, :mailbox)
      leaked = leaked(results)

      # No named behaviour, but a handle_info/2 — the reply is consumed.
      refute Enum.any?(leaked, fn [func, _id] -> String.contains?(func, "PlainTaskConsumer") end)
      assert Enum.any?(leaked, fn [func, _id] -> String.contains?(func, "fire_and_forget") end)
    end

    test "does not flag Task.Supervisor.async_nolink as leaked" do
      modules = [
        Argus.Test.Fixtures.SupervisedFireAndForget,
        Argus.Test.Fixtures.LeakedTaskModule
      ]

      assert {:ok, results} = Memo.analyze(modules, :mailbox)

      leaked = leaked(results)

      # async_nolink is managed by the supervisor — not a leak.
      refute Enum.any?(leaked, fn [func, _id] ->
               String.contains?(func, "SupervisedFireAndForget")
             end)

      # Bare Task.async without await is still flagged.
      assert Enum.any?(leaked, fn [func, _id] ->
               String.contains?(func, "fire_and_forget")
             end)
    end

    test "suppresses task factory (tail-position async)" do
      modules = [
        Argus.Test.Fixtures.TaskFactory,
        Argus.Test.Fixtures.LeakedTaskModule
      ]

      assert {:ok, results} = Memo.analyze(modules, :mailbox)

      leaked = leaked(results)

      # TaskFactory returns the task in tail position, or on every way out
      # after other work — not a leak.
      refute Enum.any?(leaked, fn [func, _id] ->
               String.contains?(func, "TaskFactory")
             end)

      # LeakedTaskModule.fire_and_forget is still flagged.
      assert Enum.any?(leaked, fn [func, _id] ->
               String.contains?(func, "fire_and_forget")
             end)
    end

    test "suppresses leaked_async_task for LiveView with handle_info/2" do
      modules = [
        Argus.Test.Fixtures.LiveViewTaskConsumer,
        Argus.Test.Fixtures.LeakedTaskModule
      ]

      assert {:ok, results} = Memo.analyze(modules, :mailbox)

      leaked = leaked(results)

      # LiveViewTaskConsumer handles task results via handle_info — not leaked.
      refute Enum.any?(leaked, fn [func, _id] ->
               String.contains?(func, "LiveViewTaskConsumer")
             end)

      # LeakedTaskModule.fire_and_forget is still flagged.
      assert Enum.any?(leaked, fn [func, _id] ->
               String.contains?(func, "fire_and_forget")
             end)
    end

    test "suppresses leaked_async_task for gen_statem with handle_event/4" do
      modules = [
        Argus.Test.Fixtures.GenStatemTaskConsumer,
        Argus.Test.Fixtures.LeakedTaskModule
      ]

      assert {:ok, results} = Memo.analyze(modules, :mailbox)

      leaked = leaked(results)

      # GenStatemTaskConsumer handles task results via handle_event — not leaked.
      refute Enum.any?(leaked, fn [func, _id] ->
               String.contains?(func, "GenStatemTaskConsumer")
             end)

      # LeakedTaskModule.fire_and_forget is still flagged.
      assert Enum.any?(leaked, fn [func, _id] ->
               String.contains?(func, "fire_and_forget")
             end)
    end

    test "suppresses leaked_async_task when Task.shutdown is used" do
      modules = [
        Argus.Test.Fixtures.TaskShutdownUser,
        Argus.Test.Fixtures.LeakedTaskModule
      ]

      assert {:ok, results} = Memo.analyze(modules, :mailbox)

      leaked = leaked(results)

      # TaskShutdownUser consumes the task via Task.shutdown — not leaked.
      refute Enum.any?(leaked, fn [func, _id] ->
               String.contains?(func, "TaskShutdownUser")
             end)

      # LeakedTaskModule.fire_and_forget is still flagged.
      assert Enum.any?(leaked, fn [func, _id] ->
               String.contains?(func, "fire_and_forget")
             end)
    end
  end

  describe "linked tasks" do
    test "yield on a linked task is reported unless the process traps exits" do
      assert {:ok, results} =
               Memo.analyze(
                 [
                   Argus.Test.Fixtures.YieldsLinkedTask,
                   Argus.Test.Fixtures.TrapsAndYields,
                   Argus.Test.Fixtures.TrapsButYieldsInClient,
                   Argus.Test.Fixtures.TrapsAroundTasks,
                   Argus.Test.Fixtures.TrapsInHelperBeforeTask,
                   Argus.Test.Fixtures.TrapsAfterTask,
                   Argus.Test.Fixtures.ClearsBeforeTask
                 ],
                 :mailbox
               )

      # The trap is the process's at the task's start (trapping_at): the
      # trapping server's handle_call is covered, its client function, run
      # in callers, is not; a function that traps before it starts the
      # tasks, itself or through a helper, is covered, and one that traps
      # only after the start, or clears the flag first, is not.
      funcs = results |> tasks("yield_linked") |> Enum.map(&hd/1) |> Enum.sort()

      assert funcs == [
               "Argus.Test.Fixtures.ClearsBeforeTask:handle_call/3",
               "Argus.Test.Fixtures.TrapsAfterTask:fetch/1",
               "Argus.Test.Fixtures.TrapsButYieldsInClient:fetch/1",
               "Argus.Test.Fixtures.YieldsLinkedTask:fan_out/1"
             ]
    end

    test "Task.async in a plain library function is noted; a GenServer's is not" do
      assert {:ok, results} =
               Memo.analyze(
                 [Argus.Test.Fixtures.LibraryPmap, Argus.Test.Fixtures.GenServerTaskConsumer],
                 :mailbox
               )

      funcs = Enum.map(tasks(results, "linked_in_library"), &hd/1)
      assert funcs == ["Argus.Test.Fixtures.LibraryPmap:pmap/2"]
    end

    test "a process module's API runs in its caller; its own callbacks do not" do
      assert {:ok, results} =
               Memo.analyze(
                 [
                   Argus.Test.Fixtures.PoolCallSupervisor,
                   Argus.Test.Fixtures.ServerSideTaskAwait
                 ],
                 :mailbox
               )

      funcs = Enum.map(tasks(results, "linked_in_library"), &hd/1)
      assert funcs == ["Argus.Test.Fixtures.PoolCallSupervisor:call/2"]
    end
  end
end
