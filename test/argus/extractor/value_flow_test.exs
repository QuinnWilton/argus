defmodule Argus.Extractor.ValueFlowTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Argus.Extractor.ValueFlow

  # A function of `n` instructions: each writes "x0" with the union of
  # what reaches its reads, plus its own token when it is a source.
  # Reads may reach back (a loop) as well as forward.
  defp function_gen do
    gen all(
          n <- integer(1..24),
          reads <-
            list_of(
              list_of(
                one_of([
                  tuple({constant(:def), integer(0..(n - 1))}),
                  tuple({constant(:param), integer(0..2)})
                ]),
                max_length: 3
              ),
              length: n
            ),
          sources <- list_of(boolean(), length: n)
        ) do
      reads =
        reads
        |> Enum.with_index()
        |> Enum.reject(fn {froms, _idx} -> froms == [] end)
        |> Map.new(fn {froms, idx} -> {idx, %{"x0" => froms}} end)

      {n, reads, sources |> Enum.with_index() |> Map.new(fn {s, i} -> {i, s} end)}
    end
  end

  defp transfer(idx, outs, reads, sources) do
    value = Map.get(ValueFlow.inputs(reads, outs, idx, &{:param, &1}), "x0", MapSet.new())
    if sources[idx], do: MapSet.put(value, {:token, idx}), else: value
  end

  # A pass over every instruction until nothing changes.
  defp round_robin(n, reads, sources, outs \\ %{}) do
    next =
      Enum.reduce(0..(n - 1), outs, fn idx, acc ->
        Map.put(acc, {idx, "x0"}, transfer(idx, acc, reads, sources))
      end)

    if next == outs, do: outs, else: round_robin(n, reads, sources, next)
  end

  property "the worklist reaches the fixpoint a pass over every instruction does" do
    check all({n, reads, sources} <- function_gen()) do
      {outs, :state} =
        ValueFlow.solve(Enum.to_list(0..(n - 1)), reads, :state, fn idx, outs, state ->
          {[{"x0", transfer(idx, outs, reads, sources)}], state, []}
        end)

      assert outs == round_robin(n, reads, sources)
    end
  end

  test "an instruction named in `also` is evaluated again" do
    # 1 reads nothing but copies what the state says 0 saw; 0 writes a
    # token once, then tells 1 to look again.
    reads = %{}

    {outs, seen} =
      ValueFlow.solve([1, 0], reads, nil, fn
        0, _outs, _seen -> {[{"x0", MapSet.new([:a])}], :a, [1]}
        1, _outs, seen -> {[{"x0", MapSet.new(List.wrap(seen))}], seen, []}
      end)

    assert seen == :a
    assert outs[{1, "x0"}] == MapSet.new([:a])
  end

  test "exhausting an explicit budget fails instead of returning a partial fixpoint" do
    reads = %{0 => %{"x0" => [{:def, 0}]}}

    assert_raise ArgumentError, ~r/budget exhausted at instruction 0/, fn ->
      ValueFlow.solve(
        [0],
        reads,
        0,
        fn 0, _outs, count -> {[{"x0", count + 1}], count + 1, []} end,
        max_evaluations: 5
      )
    end
  end

  test "a finite chain can require more than 64 evaluations of an instruction" do
    reads = %{0 => %{"x0" => [{:def, 0}]}}

    {outs, nil} =
      ValueFlow.solve([0], reads, nil, fn 0, outs, nil ->
        value = min(Map.get(outs, {0, "x0"}, 0) + 1, 100)
        {[{"x0", value}], nil, []}
      end)

    assert outs[{0, "x0"}] == 100
  end

  test "only the last write to a register determines whether it changed" do
    reads = %{0 => %{"x0" => [{:def, 0}]}}

    {outs, evaluations} =
      ValueFlow.solve(
        [0, 0],
        reads,
        0,
        fn 0, _outs, count ->
          {[{"x0", :intermediate}, {"x0", :final}], count + 1, []}
        end,
        max_evaluations: 3
      )

    assert outs[{0, "x0"}] == :final
    assert evaluations == 2
  end

  property "schedule reversal and duplicated reaching edges preserve the solution" do
    check all({n, reads, sources} <- function_gen()) do
      duplicated =
        Map.new(reads, fn {idx, regs} ->
          {idx, Map.new(regs, fn {reg, froms} -> {reg, froms ++ Enum.reverse(froms)} end)}
        end)

      {outs, nil} =
        ValueFlow.solve(Enum.reverse(Enum.to_list(0..(n - 1))), duplicated, nil, fn idx,
                                                                                    outs,
                                                                                    nil ->
          {[{"x0", transfer(idx, outs, duplicated, sources)}], nil, []}
        end)

      assert outs == round_robin(n, reads, sources)
    end
  end

  test "reads_by_function groups a module's reaching definitions by function" do
    use_at = fn func, idx -> %Argus.InstrId{module: "M", func: func, arity: 1, idx: idx} end

    reaching = [
      {{:param, 0}, "x0", use_at.("f", 1)},
      {use_at.("f", 1), "x0", use_at.("f", 2)},
      {use_at.("g", 3), "y0", use_at.("g", 4)}
    ]

    assert ValueFlow.reads_by_function(reaching) == %{
             "M:f/1" => %{1 => %{"x0" => [{:param, 0}]}, 2 => %{"x0" => [{:def, 1}]}},
             "M:g/1" => %{4 => %{"y0" => [{:def, 3}]}}
           }
  end
end
