defmodule Argus.Extractors.TermFlowHigherOrderTest do
  @moduledoc """
  TermFlow follows a value through a library call running one of the
  program's funs on a list's elements (`element_fun`), records what each
  Task operation is handed (`task_op_source`), and what a call it does
  not follow through is handed (`value_escape`).
  """
  use ExUnit.Case, async: true
  alias Argus.Extractors.TermFlow

  defp unsited(rows), do: Enum.map(rows, &tl/1)

  setup_all do
    [{_mod, bin}] =
      Code.compile_string("""
      defmodule Argus.TermFlowTest.Higher do
        def mapped(xs), do: Enum.map(xs, fn x -> {x, self()} end)
        def folded(xs, init), do: Enum.reduce(xs, init, fn x, acc -> [x | acc] end)
        def each(xs), do: Enum.each(xs, fn x -> x end)
        def captured(tasks), do: Enum.map(tasks, &Task.await/1)
        def awaited(task), do: Task.await(task)
        def stored(table, x), do: :ets.insert(table, {:key, x})
        def zipped_reduce(xs, ys), do: Enum.zip_reduce(xs, ys, [], fn x, y, acc -> [{x, y} | acc] end)
        def reversed(xs), do: :lists.reverse(xs)
        def joined(xs, ys), do: xs ++ ys
        def sent(pid, x), do: send(pid, {:x, x})
        def called(fun, x), do: fun.(x)
        def enumerated_map(x), do: Enum.map(%{key: x}, fn {_k, v} -> v end)
        def kept(x), do: Process.put(:key, x)
        def kept_anywhere(key, x), do: Process.put(key, x)
        def keyed(key, x), do: %{key => x}
        def monitor_all(pids), do: Enum.each(pids, &Process.monitor/1)
        def updated_from(map, x), do: Enum.map(%{map | a: x}, fn {_k, v} -> v end)
        def updated_local(x, y), do: Enum.map(Map.put(%{a: x}, :b, y), fn {_k, v} -> v end)
        def put_keyed(map, key, x), do: Map.put(map, key, x)
        def listed(tuple), do: Tuple.to_list(tuple)
        def set_second(tuple, x), do: put_elem(tuple, 1, x)
        def into_list(xs), do: Enum.into(xs, [])
        def into_map(pairs), do: Enum.into(pairs, %{})
      end
      """)

    {:ok, raw} = Argus.Pipeline.extract([bin], extractors: [TermFlow])

    rows =
      Map.new(raw, fn {relation, rows} ->
        {relation,
         Enum.map(rows, fn row ->
           Enum.map(row, &String.replace(&1, "Argus.TermFlowTest.Higher:", ""))
         end)}
      end)

    %{rows: rows}
  end

  test "a map's answer is a list of the fun's, and the fun is handed each element", %{
    rows: rows
  } do
    assert [["mapped/1#" <> _ = site, "mapped/1", "-mapped/1-fun-0-/1", "kept"]] =
             rows.element_fun
             |> Enum.filter(&(Enum.at(&1, 1) == "mapped/1"))

    assert [site, "mapped/1", "-mapped/1-fun-0-/1"] in rows.value_result

    assert Enum.any?(rows.value_object, &match?(["mapped/1", _, "list", _, _], &1))
    assert Enum.any?(rows.value_field, &match?(["mapped/1", _, "[]", "result", ^site], &1))

    # The element is a load of the list's `[]`, the list a parameter.
    assert Enum.any?(
             rows.value_arg,
             &match?([^site, "mapped/1", "-mapped/1-fun-0-/1", "0", "element", "load", _], &1)
           )

    assert Enum.any?(rows.value_load, &match?(["mapped/1", _, "[]", "param", "0"], &1))
  end

  test "a fold's answer and accumulator are the fun's answer and the first accumulator",
       %{rows: rows} do
    [site] = for [s, "folded/2", _, "kept"] <- rows.element_fun, do: s

    assert [site, "folded/2", "-folded/2-fun-0-/2"] in rows.value_result
    assert ["folded/2", "result", site] in rows.value_return
    assert ["folded/2", "param", "1"] in rows.value_return
    fun = "-folded/2-fun-0-/2"
    assert [site, "folded/2", fun, "1", "element", "param", "1"] in rows.value_arg
    assert [site, "folded/2", fun, "1", "element", "result", site] in rows.value_arg
  end

  test "Enum.each runs the fun and drops its answer", %{rows: rows} do
    assert [[_site, "each/1", "-each/1-fun-0-/1", "dropped"]] =
             for(r = [_, "each/1", _, _] <- rows.element_fun, do: r)

    refute Enum.any?(rows.value_result, &match?([_, "each/1", _], &1))
  end

  test "a Task operation is handed the task, or the list it runs on", %{rows: rows} do
    assert Enum.any?(rows.task_op_source, &match?([_, "awaited/1", "await", "param", "0"], &1))
    # A capture is handed each element: a `[]` load of the list.
    assert [[_, "captured/1", "await", "load", load]] =
             Enum.filter(rows.task_op_source, &match?([_, "captured/1" | _], &1))

    assert ["captured/1", load, "[]", "param", "0"] in rows.value_load
  end

  test "a library call value flow does not follow through is an escape", %{rows: rows} do
    escapes = unsited(rows.value_escape)

    assert Enum.any?(escapes, &match?(["stored/2", "obj", _], &1))
    assert ["zipped_reduce/2", "param", "0"] in escapes
    assert ["zipped_reduce/2", "param", "1"] in escapes
    assert Enum.any?(escapes, &match?(["sent/2", "obj", _], &1))
    assert ["called/2", "param", "1"] in escapes
    assert ["kept_anywhere/2", "param", "1"] in escapes
  end

  test "followed calls are no escape: reorders, joins, puts under a literal key, the program's funs",
       %{rows: rows} do
    escaping = rows.value_escape |> unsited() |> Enum.map(&hd/1) |> MapSet.new()

    for func <- ~w(mapped/1 folded/2 each/1 captured/1 awaited/1 reversed/1 joined/2 kept/1) do
      refute MapSet.member?(escaping, func), func
    end

    assert ["reversed/1", "param", "0"] in rows.value_return
    assert ["joined/2", "param", "0"] in rows.value_return
    assert ["joined/2", "param", "1"] in rows.value_return
  end

  test "enumerating a map built here hands the fun {key, value} pairs", %{rows: rows} do
    [site] = for [s, "enumerated_map/1", _, "kept"] <- rows.element_fun, do: s
    fun = "-enumerated_map/1-fun-0-/1"

    assert [[^site, "enumerated_map/1", ^fun, "0", "element", "obj", pair]] =
             Enum.filter(rows.value_arg, &match?([^site, _, ^fun, "0" | _], &1))

    assert ["enumerated_map/1", pair, "tuple", "", "2"] in rows.value_object
    assert ["enumerated_map/1", pair, "{1}", "param", "0"] in rows.value_field
    refute Enum.any?(rows.value_escape, &match?([_, "enumerated_map/1" | _], &1))
  end

  test "a key not a literal is what a map holds under @key", %{rows: rows} do
    assert Enum.any?(rows.value_field, &match?(["keyed/2", _, "@key", "param", "0"], &1))
    assert Enum.any?(rows.value_field, &match?(["keyed/2", _, "*", "param", "1"], &1))
    assert Enum.any?(rows.value_field, &match?(["put_keyed/3", _, "@key", "param", "1"], &1))
  end

  test "Tuple.to_list/1 reads any field; put_elem/3 sets the one it names", %{rows: rows} do
    assert Enum.any?(rows.value_load, &match?(["listed/1", _, "**", "param", "0"], &1))
    assert Enum.any?(rows.value_field, &match?(["set_second/2", _, "{1}", "param", "1"], &1))
    assert Enum.any?(rows.value_base, &match?(["set_second/2", _, "param", "0"], &1))
    assert Enum.any?(rows.value_sets, &match?([_, "{1}"], &1))
  end

  test "Enum.into/2 collects into the literal it is handed", %{rows: rows} do
    assert Enum.any?(rows.value_object, &match?(["into_list/1", _, "list", _, _], &1))
    refute Enum.any?(rows.value_object, &match?(["into_list/1", _, "map", _, _], &1))
    assert Enum.any?(rows.value_object, &match?(["into_map/1", _, "map", _, _], &1))
    refute Enum.any?(rows.value_object, &match?(["into_map/1", _, "list", _, _], &1))
  end

  test "enumerating an updated map yields its own pairs and its base's", %{rows: rows} do
    # From a parameter: the base's pairs are a `[]` load of it.
    fun = "-updated_from/2-fun-0-/1"

    args =
      for [_, "updated_from/2", ^fun, "0", "element", kind, src] <- rows.value_arg,
          do: {kind, src}

    assert Enum.any?(args, &match?({"obj", _}, &1))
    assert Enum.any?(args, &match?({"load", _}, &1))
    assert Enum.any?(rows.value_load, &match?(["updated_from/2", _, "[]", "param", "0"], &1))

    # Built here (the compiler folds the put into one literal): a pair
    # whose value is either field's.
    fun = "-updated_local/2-fun-0-/1"
    [pair] = for [_, "updated_local/2", ^fun, "0", "element", "obj", p] <- rows.value_arg, do: p
    seconds = for ["updated_local/2", ^pair, "{1}", "param", n] <- rows.value_field, do: n
    assert Enum.sort(seconds) == ["0", "1"]
  end

  test "a signal captured as the fun goes to each element", %{rows: rows} do
    assert [[_, "monitor_all/1", "monitor", "load", load]] =
             Enum.filter(rows.process_signal_source, &match?([_, "monitor_all/1" | _], &1))

    assert ["monitor_all/1", load, "[]", "param", "0"] in rows.value_load
    refute Enum.any?(rows.value_escape, &match?([_, "monitor_all/1" | _], &1))
  end
end
