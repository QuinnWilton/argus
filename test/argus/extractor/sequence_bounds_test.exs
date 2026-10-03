defmodule Argus.Extractor.SequenceBoundsTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Argus.Extractor.CallSites
  alias Argus.Extractor.Helpers
  alias Argus.Extractors.ParamFlow.SequenceBounds
  alias Argus.Extractors.ParamFlow.SequenceBounds.Value
  alias Argus.Pipeline.Disassemble

  setup_all do
    {:ok, data} = Disassemble.disassemble_path(to_string(:code.which(:sequence_bounds_fixture)))
    data = Map.put(data, :cfg, data |> Helpers.typed() |> Argus.Cfg.build())
    sites = CallSites.for_module(data)
    %{data: data, sites: sites, bounded: SequenceBounds.bounded_sites(data, sites)}
  end

  test "recursive character accumulators survive tuple fields and a late singleton guard", %{
    bounded: bounded
  } do
    assert Enum.any?(bounded, fn {f, _} -> f == ":sequence_bounds_fixture:leaf/1" end)
  end

  test "numeric guards bound only the characters of a successful atom conversion", %{
    bounded: bounded
  } do
    assert Enum.any?(bounded, fn {f, _} -> f == ":sequence_bounds_fixture:float_range/1" end)

    assert Enum.any?(bounded, fn {f, _} ->
             f == ":sequence_bounds_fixture:guard_alternatives/1"
           end)
  end

  test "unknown alphabets, callers, fields, lengths and captured helpers do not prove a vocabulary",
       %{bounded: bounded} do
    names = Enum.map(bounded, fn {f, _} -> f end)

    for name <- [
          "unbounded/1",
          "unicode_singleton/1",
          "mixed_leaf/1",
          "wrong_field/1",
          "unchecked_tail/1",
          "exported_builder/2",
          "escaped_builder/1",
          "unknown_alphabet/1",
          "unchecked_return/2",
          "exception_value/1",
          "guard_other_copy/2",
          "saved_value/2",
          "partial_tuple/2",
          "broad_alternative/1",
          "fractional_only/1",
          "unicode_range/1"
        ] do
      refute (":sequence_bounds_fixture:" <> name) in names, name
    end
  end

  test "intra-function backedges fail closed before writer identities can be reused", %{
    data: data
  } do
    calls = CallSites.for_module(data)
    [target] = Enum.filter(calls, &(&1.func_id == ":sequence_bounds_fixture:float_range/1"))

    function =
      Enum.find(data.functions, fn {:function, f, a, _, _} -> f == :float_range and a == 1 end)

    {:function, _, _, _, instrs} = function
    cfg = Helpers.cfg(%{data | functions: [function]}, :float_range, 1)
    block = Map.fetch!(cfg.blocks, cfg.entry)
    # Both cycle nodes have a separate entry edge, so neither dominates the
    # other and a natural-loop-header test alone would miss this cycle.
    cyclic = %{
      cfg
      | entry: 0,
        loop_headers: MapSet.new(),
        blocks: %{
          0 => %{block | succs: [{1, :branch_pass}, {2, :branch_fail}]},
          1 => %{block | succs: [{2, :fallthrough}]},
          2 => %{block | succs: [{1, :fallthrough}]}
        }
    }

    data = Map.put(%{data | functions: [function]}, :cfg, %{{"float_range", 1} => cyclic})
    assert instrs != []
    assert SequenceBounds.bounded_sites(data, [target]) == MapSet.new()
  end

  test "duplicated tuple trees have an aggregate node budget" do
    leaf = Value.tuple(List.duplicate(Value.empty(), 32))
    branch = Value.tuple(List.duplicate(leaf, 32))
    assert Value.tuple(List.duplicate(branch, 32)) == :unknown

    left = Value.tuple(List.duplicate(branch, 3))
    right = Value.tuple(List.duplicate(branch, 3) ++ [:unknown])
    assert left != :unknown
    assert right != :unknown
    assert Value.join(left, right) == :unknown

    # Runtime tuples share these children; the abstract literal walker must not
    # expand all 32^16 paths before noticing its depth or node limit.
    literal =
      Enum.reduce(1..16, [], fn _round, child ->
        List.duplicate(child, 32) |> List.to_tuple()
      end)

    assert Value.literal(literal) == :unknown
  end

  property "joining, reversing and appending retain their concrete character sequences" do
    check all(
            left <- list_of(integer(0..0x10FFFF), max_length: 6),
            right <- list_of(integer(0..0x10FFFF), max_length: 6)
          ) do
      a = Value.literal(left)
      b = Value.literal(right)
      joined = Value.join(a, b)

      assert contains_sequence?(joined, left)
      assert contains_sequence?(joined, right)
      assert contains_sequence?(Value.reverse(joined), Enum.reverse(left))
      assert contains_sequence?(Value.reverse(joined), Enum.reverse(right))
      assert contains_sequence?(Value.append(a, b), left ++ right)
      assert Value.join(a, b) == Value.join(b, a)
    end
  end

  property "a finite proof never admits more than 1024 distinct character strings" do
    check all(first <- integer(0..100), width <- integer(1..40), size <- integer(1..8)) do
      character =
        :unknown
        |> Value.range(:ge, first, :right)
        |> Value.range(:lt, first + width, :right)

      sequence =
        Enum.reduce(1..size, Value.empty(), fn _, tail -> Value.cons(character, tail) end)

      for value <- [sequence, Value.reverse(sequence)] do
        if Value.finite_chars?(value), do: assert(Integer.pow(width, size) <= 1024)
      end
    end
  end

  defp contains_sequence?(:unknown, _sequence), do: true

  defp contains_sequence?({:cons, {:literal, head}, tail}, [head | rest]),
    do: contains_sequence?(tail, rest)

  defp contains_sequence?({:list, alphabet, lo, hi}, sequence) do
    length(sequence) >= lo and (hi == :infinity or length(sequence) <= hi) and
      Enum.all?(sequence, fn character ->
        case alphabet do
          :any -> true
          {first, last} -> character >= first and character <= last
          :none -> false
        end
      end)
  end

  defp contains_sequence?(_, _sequence), do: false

  test "hard budgets publish no partial proofs", %{data: data, sites: sites} do
    assert SequenceBounds.bounded_sites(data, sites, max_rounds: 1) == MapSet.new()
    assert SequenceBounds.bounded_sites(data, sites, max_steps: 1) == MapSet.new()
    assert SequenceBounds.bounded_sites(data, sites, max_functions: 1) == MapSet.new()
  end
end
