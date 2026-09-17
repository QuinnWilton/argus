defmodule Argus.Extractor.DispatchTotalTest do
  use ExUnit.Case, async: true

  alias Argus.Test.Fixtures.CatchAllShapes

  defp callback_total(mod) do
    {:ok, facts} = Argus.Pipeline.extract([mod], extractors: [Argus.Extractors.CallbackTag])
    Map.get(facts, :callback_total, [])
  end

  # `use GenServer` injects catch-all defaults for the callbacks a module
  # does not define, so only the callback the fixture writes is asked about.
  test "a clause that accepts every message while patterning the state is a catch-all" do
    rows = callback_total(CatchAllShapes.StatePatternCatchAll)
    assert Enum.any?(rows, &match?([_, "handle_info"], &1))
  end

  test "a state read at the top of a body does not turn a partial callback into a catch-all" do
    rows = callback_total(CatchAllShapes.MapAccessBody)
    refute Enum.any?(rows, &match?([_, "handle_cast"], &1))
  end

  test "tagged clauses that also pattern the state are not a catch-all" do
    rows = callback_total(CatchAllShapes.TaggedClausesWithStatePatterns)
    refute Enum.any?(rows, &match?([_, "handle_info"], &1))
  end

  test "a clause that shares a tested prefix with the one before it is not a catch-all" do
    rows = callback_total(CatchAllShapes.SharedPrefixClauses)
    refute Enum.any?(rows, &match?([_, "handle_info"], &1))
  end
end
