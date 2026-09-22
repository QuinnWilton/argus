defmodule Argus.Analyses.FailureWhereisTest do
  use ExUnit.Case

  alias Argus.Souffle

  defp skip_without_souffle do
    unless Souffle.available?(), do: flunk("souffle not installed")
  end

  defp analyze(modules) do
    assert {:ok, results} = Argus.analyze(modules, :failure)
    results
  end

  describe "whereis_race" do
    test "flags a static-name whereis call site" do
      skip_without_souffle()

      results = analyze([Argus.Test.Fixtures.StaticWhereis])

      assert Enum.any?(results["whereis_race"], fn [_id, func, name] ->
               String.contains?(func, "StaticWhereis:lookup/0") and name == ":my_process"
             end)
    end

    test "does not flag whereis on a runtime-computed name" do
      skip_without_souffle()

      # WhereisModule's lookups take the name as an argument — the rule
      # only speaks about statically-known names.
      results = analyze([Argus.Test.Fixtures.WhereisModule])

      assert results["whereis_race"] == []
    end
  end
end
