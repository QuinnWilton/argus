defmodule Argus.Analyses.MailboxTaskHandlesTest do
  @moduledoc """
  A task is collected when its own handle reaches a Task operation, and
  value flow follows the handle out of the closures comprehensions and
  Enum callbacks start it in (#10), through lists and other terms, calls,
  returns and a server's state (`clientlib/task_handles.dl`). A handle
  value flow loses (`task_escapes`) is not reported.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties
  @moduletag :souffle

  alias Argus.Test.BatchProperty
  alias Argus.Test.Fixtures.TaskHandles
  alias Argus.Test.Memo
  alias Argus.Test.Rows

  defp never_awaited(results),
    do:
      results
      |> Rows.where(:mailbox, "task_result_defect", kind: "never_awaited", drop: [:kind])
      |> Enum.map(&hd/1)

  defp unhandled(results),
    do:
      for(
        [_mod, func, _id, message, source | _] <- results["unhandled_info"],
        do: {func, message, source}
      )

  # The function a start's row names, without its closure's suffix: the
  # named function it is written in.
  defp written_in(func) do
    case Regex.run(~r/^(.*):-([^\/]+)\/(\d+)-fun-\d+-\/\d+$/, func) do
      [_, mod, name, arity] -> "#{mod}:#{name}/#{arity}"
      nil -> func
    end
  end

  describe "never_awaited" do
    test "a task collected wherever its handle goes is not reported" do
      {:ok, results} =
        Memo.analyze([TaskHandles.Collected, TaskHandles.StateServer], :mailbox)

      assert never_awaited(results) == []
    end

    test "a task whose handle value flow loses is not reported" do
      {:ok, results} = Memo.analyze([TaskHandles.Escaped], :mailbox)
      assert never_awaited(results) == []
    end

    test "every leaked task is reported where it starts" do
      {:ok, results} = Memo.analyze([TaskHandles.Leaked], :mailbox)
      leaked = "Argus.Test.Fixtures.TaskHandles.Leaked"

      assert results |> never_awaited() |> Enum.map(&written_in/1) |> Enum.sort() == [
               "#{leaked}:awaits_another/1",
               "#{leaked}:each/1",
               "#{leaked}:filtered_dropped/1",
               "#{leaked}:flat_mapped_and_dropped/1",
               "#{leaked}:helper_drops/1",
               "#{leaked}:in_a_predicate/1",
               "#{leaked}:mapped_and_dropped/1",
               "#{leaked}:reduced_and_dropped/1",
               "#{leaked}:start/1",
               "#{leaked}:supervised_dropped/2",
               "#{leaked}:two_generators_dropped/2"
             ]
    end

    test "the reported comprehension (#10) is quiet, its own start included" do
      {:ok, results} = Memo.analyze([TaskHandles.Collected], :mailbox)

      refute Enum.any?(
               never_awaited(results),
               &String.contains?(&1, "two_generators")
             )
    end
  end

  describe "an async_nolink task's reply and :DOWN" do
    test "do not reach handle_info/2 when its own task is collected, wherever" do
      {:ok, results} =
        Memo.analyze([TaskHandles.NolinkMapped, TaskHandles.NolinkHelper], :mailbox)

      assert unhandled(results) == []
    end

    test "reach it when only another task is collected" do
      {:ok, results} = Memo.analyze([TaskHandles.NolinkCollectsAnother], :mailbox)
      func = "Argus.Test.Fixtures.TaskHandles.NolinkCollectsAnother:handle_call/3"

      assert Enum.sort(unhandled(results)) == [
               {func, "{:DOWN, …}", "task"},
               {func, "{ref, …}", "task"}
             ]
    end

    test "reach it from Task.Supervisor.async_nolink/3" do
      {:ok, results} = Memo.analyze([TaskHandles.NolinkThreeArity], :mailbox)
      func = "Argus.Test.Fixtures.TaskHandles.NolinkThreeArity:handle_cast/2"

      assert Enum.sort(unhandled(results)) == [
               {func, "{:DOWN, …}", "task"},
               {func, "{ref, …}", "task"}
             ]
    end
  end

  # ── Generated shapes ────────────────────────────────────────────────
  #
  # A start written as a comprehension (one to three generators, with or
  # without a filter) or as an Enum or :lists callback, with Task.async
  # or Task.Supervisor.async, and a fate for the tasks it makes: each
  # fate collects them, drops them, or hands them where value flow does
  # not follow. Only the dropped ones are reported.

  @collected [:await_many, :await_capture, :await_each, :yield_many, :helper, :reversed, :joined]
  @dropped [:dropped, :each_dropped, :filter_dropped]
  @escaped [:sent, :returned, :stored]

  defp a_case do
    gen all(
          shape <- member_of([:for, :map, :reduce, :flat_map, :foldl, :erlang_map]),
          generators <- integer(1..3),
          filter <- boolean(),
          start <- member_of([:async, :supervised]),
          fate <- member_of(@collected ++ @dropped ++ @escaped)
        ) do
      %{shape: shape, generators: generators, filter: filter, start: start, fate: fate}
    end
  end

  defp start_code(%{start: :async}, value), do: "Task.async(fn -> #{value} end)"

  defp start_code(%{start: :supervised}, value),
    do: "Task.Supervisor.async(sup, fn -> #{value} end)"

  defp tasks_code(%{shape: :for, generators: n, filter: filter} = c) do
    vars = for i <- 1..n, do: "x#{i}"
    generators = Enum.map_join(vars, ", ", &"#{&1} <- xs")
    filter = if filter, do: ", x1 > 0", else: ""
    "for #{generators}#{filter}, do: #{start_code(c, Enum.join(vars, " + "))}"
  end

  defp tasks_code(%{shape: :map} = c), do: "Enum.map(xs, fn x -> #{start_code(c, "x")} end)"

  defp tasks_code(%{shape: :reduce} = c),
    do: "Enum.reduce(xs, [], fn x, acc -> [#{start_code(c, "x")} | acc] end)"

  defp tasks_code(%{shape: :flat_map} = c),
    do: "Enum.flat_map(xs, fn x -> [#{start_code(c, "x")}] end)"

  defp tasks_code(%{shape: :foldl} = c),
    do: ":lists.foldl(fn x, acc -> [#{start_code(c, "x")} | acc] end, [], xs)"

  defp tasks_code(%{shape: :erlang_map} = c),
    do: ":lists.map(fn x -> #{start_code(c, "x")} end, xs)"

  defp fate_code(:await_many), do: "Task.await_many(tasks)"
  defp fate_code(:await_capture), do: "Enum.map(tasks, &Task.await/1)"
  defp fate_code(:await_each), do: "Enum.each(tasks, fn task -> Task.await(task) end)"

  defp fate_code(:yield_many),
    do: "Task.yield_many(tasks) |> Enum.map(fn {task, r} -> r || Task.shutdown(task) end)"

  defp fate_code(:helper), do: "await_all(tasks)"
  defp fate_code(:reversed), do: "tasks |> Enum.reverse() |> Task.await_many()"
  defp fate_code(:joined), do: "Task.await_many(tasks ++ [])"
  defp fate_code(:dropped), do: "_ = tasks\n    :ok"
  defp fate_code(:each_dropped), do: "Enum.each(tasks, fn _task -> :ok end)"
  defp fate_code(:filter_dropped), do: "Enum.filter(tasks, fn _task -> true end)\n    :ok"
  defp fate_code(:sent), do: "send(self(), {:tasks, tasks})"
  defp fate_code(:returned), do: "tasks"
  defp fate_code(:stored), do: ":ets.insert(:tasks, {:tasks, tasks})"

  # A run's cases are functions of one module, solved together
  # (`Argus.Test.BatchProperty`): no case calls another's function or
  # receives what another sends, and `:tasks` is a table only written,
  # never read.
  defp module_source(cases) do
    body =
      Enum.map_join(cases, "\n\n", fn {name, c} ->
        """
          def #{name}(xs, sup) do
            _ = sup
            tasks = #{tasks_code(c)}
            #{fate_code(c.fate)}
          end
        """
      end)

    digest = :crypto.hash(:sha256, body) |> Base.encode16() |> binary_part(0, 12)

    """
    defmodule Argus.Test.Generated.TaskFate#{digest} do
    #{body}

      def await_all(tasks), do: Task.await_many(tasks)
    end
    """
  end

  defp assert_reported_if_dropped(c, results) do
    reported? = never_awaited(results) != []

    assert reported? == c.fate in @dropped,
           "#{if reported?, do: "reported", else: "not reported"}: #{inspect(c)}\n" <>
             module_source([{"case_0", c}])
  end

  # A wrong case shrinks with a solve a step, past the default timeout.
  @tag timeout: 300_000
  property "only the tasks a generated function drops are reported" do
    BatchProperty.check_cases(a_case(),
      analysis: :mailbox,
      count: 32,
      source: &module_source/1,
      assert: &assert_reported_if_dropped/2
    )
  end
end
