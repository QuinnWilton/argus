defmodule Argus.Analyses.MailboxTaskTest do
  use ExUnit.Case

  alias Argus.Souffle
  alias Argus.Test.Rows

  defp skip_without_souffle do
    unless Souffle.available?(), do: flunk("souffle not installed")
  end

  defp tasks(results, kind),
    do: Rows.where(results, :mailbox, "task_result_defect", kind: kind, drop: [:kind])

  defp leaked(results), do: tasks(results, "never_awaited")

  describe "task_result_defect: never_awaited" do
    test "detects leaked async task" do
      skip_without_souffle()

      assert {:ok, results} =
               Argus.analyze([Argus.Test.Fixtures.LeakedTaskModule], :mailbox)

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
      skip_without_souffle()

      modules = [
        Argus.Test.Fixtures.GenServerTaskConsumer,
        Argus.Test.Fixtures.LeakedTaskModule
      ]

      assert {:ok, results} = Argus.analyze(modules, :mailbox)

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
      skip_without_souffle()

      modules = [
        Argus.Test.Fixtures.PlainTaskConsumer,
        Argus.Test.Fixtures.LeakedTaskModule
      ]

      assert {:ok, results} = Argus.analyze(modules, :mailbox)
      leaked = leaked(results)

      # No named behaviour, but a handle_info/2 — the reply is consumed.
      refute Enum.any?(leaked, fn [func, _id] -> String.contains?(func, "PlainTaskConsumer") end)
      assert Enum.any?(leaked, fn [func, _id] -> String.contains?(func, "fire_and_forget") end)
    end

    test "does not flag Task.Supervisor.async_nolink as leaked" do
      skip_without_souffle()

      modules = [
        Argus.Test.Fixtures.SupervisedFireAndForget,
        Argus.Test.Fixtures.LeakedTaskModule
      ]

      assert {:ok, results} = Argus.analyze(modules, :mailbox)

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
      skip_without_souffle()

      modules = [
        Argus.Test.Fixtures.TaskFactory,
        Argus.Test.Fixtures.LeakedTaskModule
      ]

      assert {:ok, results} = Argus.analyze(modules, :mailbox)

      leaked = leaked(results)

      # TaskFactory returns the task in tail position — not a leak.
      refute Enum.any?(leaked, fn [func, _id] ->
               String.contains?(func, "TaskFactory")
             end)

      # LeakedTaskModule.fire_and_forget is still flagged.
      assert Enum.any?(leaked, fn [func, _id] ->
               String.contains?(func, "fire_and_forget")
             end)
    end

    test "suppresses leaked_async_task for LiveView with handle_info/2" do
      skip_without_souffle()

      modules = [
        Argus.Test.Fixtures.LiveViewTaskConsumer,
        Argus.Test.Fixtures.LeakedTaskModule
      ]

      assert {:ok, results} = Argus.analyze(modules, :mailbox)

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
      skip_without_souffle()

      modules = [
        Argus.Test.Fixtures.GenStatemTaskConsumer,
        Argus.Test.Fixtures.LeakedTaskModule
      ]

      assert {:ok, results} = Argus.analyze(modules, :mailbox)

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
      skip_without_souffle()

      modules = [
        Argus.Test.Fixtures.TaskShutdownUser,
        Argus.Test.Fixtures.LeakedTaskModule
      ]

      assert {:ok, results} = Argus.analyze(modules, :mailbox)

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

    test "runs without error on modules with no task calls" do
      skip_without_souffle()

      assert {:ok, results} = Argus.analyze([:maps], :mailbox)
      assert Map.has_key?(results, "task_result_defect")
    end
  end

  describe "linked tasks" do
    test "yield on a linked task is reported unless the process traps exits" do
      skip_without_souffle()

      assert {:ok, results} =
               Argus.analyze(
                 [Argus.Test.Fixtures.YieldsLinkedTask, Argus.Test.Fixtures.TrapsAndYields],
                 :mailbox
               )

      funcs = Enum.map(tasks(results, "yield_linked"), &hd/1)
      assert funcs == ["Argus.Test.Fixtures.YieldsLinkedTask:fan_out/1"]
    end

    test "Task.async in a plain library function is noted; a GenServer's is not" do
      skip_without_souffle()

      assert {:ok, results} =
               Argus.analyze(
                 [Argus.Test.Fixtures.LibraryPmap, Argus.Test.Fixtures.GenServerTaskConsumer],
                 :mailbox
               )

      funcs = Enum.map(tasks(results, "linked_in_library"), &hd/1)
      assert funcs == ["Argus.Test.Fixtures.LibraryPmap:pmap/2"]
    end
  end
end
