defmodule Argus.Extractors.TermFlow.HeapTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Argus.Extractor.ValueFlow
  alias Argus.Extractors.TermFlow.Heap

  defp object(fields, base \\ [], keys \\ []) do
    %{
      shape: "map",
      fields: Map.new(fields, fn {k, v} -> {k, MapSet.new(v)} end),
      base: MapSet.new(base),
      keys: MapSet.new(keys)
    }
  end

  defp sources(objs, key, selector) do
    {value, _dependencies, _loads} = Heap.read(objs, MapSet.new([{:obj, key}]), selector, "read")
    value
  end

  property "literal updates agree with a concrete map interpreter, including empty overwrites" do
    check all(
            updates <-
              list_of(tuple({member_of([":a", ":b", ":c"]), list_of(integer(0..8))}),
                min_length: 1,
                max_length: 30
              ),
            selector <- member_of([":a", ":b", ":c"])
          ) do
      {objs, concrete} =
        updates
        |> Enum.with_index()
        |> Enum.reduce({%{}, %{}}, fn {{key, tokens}, idx}, {objs, concrete} ->
          base = if idx == 0, do: [], else: [{:obj, idx - 1}]
          obj = object([{key, tokens}], base, [key])
          {Map.put(objs, idx, obj), Map.put(concrete, key, MapSet.new(tokens))}
        end)

      assert sources(objs, length(updates) - 1, selector) ==
               Map.get(concrete, selector, MapSet.new())
    end
  end

  property "adding field sources cannot remove read sources" do
    check all(
            initial <- list_of(integer(0..20)),
            added <- list_of(integer(0..20)),
            unknown <- list_of(integer(0..20))
          ) do
      before = %{0 => object([{":a", initial}, {"*", unknown}])}
      after_addition = %{0 => object([{":a", initial ++ added}, {"*", unknown}])}
      assert MapSet.subset?(sources(before, 0, ":a"), sources(after_addition, 0, ":a"))
    end
  end

  property "renaming allocation sites and selectors preserves field provenance" do
    check all(tokens <- list_of(integer(0..20)), depth <- integer(1..15)) do
      objs =
        Map.new(0..depth, fn
          0 -> {0, object([{":a", tokens}])}
          idx -> {idx, object([], [{:obj, idx - 1}])}
        end)

      renamed =
        Map.new(objs, fn {idx, obj} ->
          fields = Map.new(obj.fields, fn {":a", v} -> {":renamed", v} end)
          base = MapSet.new(obj.base, fn {:obj, idx} -> {:obj, {:renamed, idx}} end)
          {{:renamed, idx}, %{obj | fields: fields, base: base}}
        end)

      assert sources(objs, depth, ":a") == sources(renamed, {:renamed, depth}, ":renamed")
    end
  end

  property "heap dependencies reach the same solution when readers run before constructors" do
    check all(
            n <- integer(1..15),
            bases <- list_of(list_of(integer(0..(n - 1)), max_length: 3), length: n),
            seeds <- list_of(boolean(), length: n)
          ) do
      objs =
        Map.new(0..(n - 1), fn idx ->
          tokens = if Enum.at(seeds, idx), do: [{:param, idx}], else: []
          base = Enum.map(Enum.at(bases, idx), &{:obj, &1})
          {idx, object([{":a", tokens}], base)}
        end)

      evaluate = fn idx, _outs, state ->
        if idx < n do
          {again, state} = Heap.commit(idx, [{idx, objs[idx]}], [], state)
          {[], state, again}
        else
          {value, dependencies, []} =
            Heap.read(state.objs, MapSet.new([{:obj, idx - n}]), ":a", "read")

          {again, state} = Heap.commit(idx, [], dependencies, state)
          {[{"x0", value}], state, again}
        end
      end

      idxs = Enum.to_list(0..(2 * n - 1))
      initial = %{objs: %{}, readers: %{}}
      {forward, _state} = ValueFlow.solve(idxs, %{}, initial, evaluate)
      {reverse, _state} = ValueFlow.solve(Enum.reverse(idxs), %{}, initial, evaluate)
      expected = Map.new(0..(n - 1), &{{&1 + n, "x0"}, sources(objs, &1, ":a")})
      assert forward == expected
      assert reverse == expected
    end
  end

  test "known overwrites shadow bases even when no source is tracked in the replacement" do
    objs = %{
      0 => object([{":a", [:old]}, {":b", [:retained]}]),
      1 => object([{":a", []}], [{:obj, 0}], [":a"])
    }

    assert sources(objs, 1, ":a") == MapSet.new()
    assert sources(objs, 1, ":b") == MapSet.new([:retained])
  end

  test "unknown-key writes may alias a literal read but do not shadow its base" do
    objs = %{0 => object([{":a", [:old]}]), 1 => object([{"*", [:new]}], [{:obj, 0}])}
    assert sources(objs, 1, ":a") == MapSet.new([:old, :new])
    assert sources(objs, 1, "*") == MapSet.new([:new])
  end

  test "external containers defer loads and scalar sources do not acquire fields" do
    value = MapSet.new([{:param, 0}, {:result, 1}, {:proc, "p"}, :self])
    {sources, [], loads} = Heap.read(%{}, value, ":a", "read")
    assert sources == MapSet.new([{:load, "read"}])
    assert Enum.sort(loads) == [{"read", ":a", {:param, 0}}, {"read", ":a", {:result, 1}}]
  end

  test "dictionary contents can be containers with deferred field loads" do
    {value, [], [{"read", ":owner", {:dict, ":container"}}]} =
      Heap.read(%{}, MapSet.new([{:dict, ":container"}]), ":owner", "read")

    assert value == MapSet.new([{:load, "read"}])
  end

  test "reading an empty object records a dependency before its fields arrive" do
    {empty, dependencies, []} = Heap.read(%{}, MapSet.new([{:obj, 0}]), ":a", "read")
    assert empty == MapSet.new()
    assert dependencies == [0]
    state = %{objs: %{}, readers: %{}}
    {[], state} = Heap.commit(1, [], dependencies, state)
    obj = object([{":a", [:later]}])
    {[1], state} = Heap.commit(0, [{0, obj}], [], state)
    assert sources(state.objs, 0, ":a") == MapSet.new([:later])
    assert {[], ^state} = Heap.commit(0, [{0, obj}], [], state)
  end

  test "cyclic bases terminate and keep sources reachable around the cycle" do
    objs = %{0 => object([], [{:obj, 1}]), 1 => object([{":a", [:token]}], [{:obj, 0}])}
    assert sources(objs, 0, ":a") == MapSet.new([:token])
    assert Heap.live(objs) == %{0 => true, 1 => true}
    empty_cycle = %{0 => object([], [{:obj, 0}])}
    assert sources(empty_cycle, 0, ":a") == MapSet.new()
    assert Heap.live(empty_cycle) == %{}
  end

  test "reconverging base paths visit each object once" do
    # Following every path here would take Fibonacci-many visits. Field
    # projection is graph reachability: visiting each vertex suffices.
    objs =
      Map.new(0..60, fn idx ->
        base = for target <- [idx + 1, idx + 2], target <= 60, do: {:obj, target}
        tokens = if idx == 60, do: [:source], else: []
        {idx, object([{":a", tokens}], base)}
      end)

    {value, dependencies, []} = Heap.read(objs, MapSet.new([{:obj, 0}]), ":a", "read")
    assert value == MapSet.new([:source])
    assert Enum.sort(dependencies) == Enum.to_list(0..60)
  end

  test "positional list traversal rejects cycles, ambiguous tails and untracked tails" do
    cons = %{
      shape: "list",
      fields: %{"[]" => MapSet.new([:head])},
      base: MapSet.new(),
      nil_tail: false
    }

    cyclic = %{cons | base: MapSet.new([{:obj, 0}])}
    value = MapSet.new([{:obj, 0}])
    assert Heap.list_elements(%{0 => cyclic}, value) == :unknown
    assert Heap.list_elements(%{0 => cons}, value) == :unknown

    assert Heap.list_elements(%{0 => %{cons | nil_tail: true}}, value) ==
             {:ok, [MapSet.new([:head])]}

    assert Heap.list_elements(%{}, MapSet.new()) == :unknown
    assert Heap.list_elements(%{}, MapSet.new([{:obj, 0}, {:obj, 1}])) == :unknown
  end
end
