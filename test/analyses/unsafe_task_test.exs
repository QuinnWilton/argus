defmodule Argus.Analyses.UnsafeTaskTest do
  use ExUnit.Case

  alias Argus.Souffle.CLI

  defp skip_without_souffle do
    unless CLI.available?(), do: flunk("souffle not installed")
  end

  describe "unsafe_task.dl" do
    test "detects leaked async task" do
      skip_without_souffle()

      assert {:ok, results} =
               Argus.analyze([Argus.Test.Fixtures.LeakedTaskModule], :unsafe_task)

      assert Map.has_key?(results, "leaked_async_task")
      leaked = results["leaked_async_task"]
      assert length(leaked) > 0

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

      assert {:ok, results} = Argus.analyze(modules, :unsafe_task)

      leaked = results["leaked_async_task"]

      # GenServerTaskConsumer handles task results via handle_info — not leaked.
      refute Enum.any?(leaked, fn [func, _id] ->
               String.contains?(func, "GenServerTaskConsumer")
             end)

      # LeakedTaskModule.fire_and_forget is still flagged.
      assert Enum.any?(leaked, fn [func, _id] ->
               String.contains?(func, "fire_and_forget")
             end)
    end

    test "detects unchecked start_child" do
      skip_without_souffle()

      assert {:ok, results} =
               Argus.analyze([Argus.Test.Fixtures.UncheckedStartChild], :unsafe_task)

      assert Map.has_key?(results, "unchecked_start_child")
      unchecked = results["unchecked_start_child"]

      funcs = Enum.map(unchecked, fn [func, _id] -> func end)

      # start_unchecked ignores the result.
      assert Enum.any?(funcs, &String.contains?(&1, "start_unchecked"))

      # start_checked uses case on the result — should NOT be flagged.
      refute Enum.any?(funcs, &String.contains?(&1, "start_checked"))

      # start_tail is a tail call — result propagated, should NOT be flagged.
      refute Enum.any?(funcs, &String.contains?(&1, "start_tail"))
    end

    test "suppresses task factory (tail-position async)" do
      skip_without_souffle()

      modules = [
        Argus.Test.Fixtures.TaskFactory,
        Argus.Test.Fixtures.LeakedTaskModule
      ]

      assert {:ok, results} = Argus.analyze(modules, :unsafe_task)

      leaked = results["leaked_async_task"]

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

      assert {:ok, results} = Argus.analyze(modules, :unsafe_task)

      leaked = results["leaked_async_task"]

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

      assert {:ok, results} = Argus.analyze(modules, :unsafe_task)

      leaked = results["leaked_async_task"]

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

      assert {:ok, results} = Argus.analyze(modules, :unsafe_task)

      leaked = results["leaked_async_task"]

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

      assert {:ok, results} = Argus.analyze([:maps], :unsafe_task)
      assert Map.has_key?(results, "leaked_async_task")
      assert Map.has_key?(results, "unchecked_start_child")
    end
  end
end
