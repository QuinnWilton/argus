defmodule Argus.Analyses.ProcessRegistryTest do
  use ExUnit.Case

  alias Argus.Souffle

  defp skip_without_souffle do
    unless Souffle.available?(), do: flunk("souffle not installed")
  end

  defp analyze(modules) do
    assert {:ok, results} = Argus.analyze(modules, :process_registry)
    results
  end

  describe "duplicate_process_name" do
    test "flags the same name registered by two modules" do
      skip_without_souffle()

      results =
        analyze([
          Argus.Test.Fixtures.ProcessRegisterer,
          Argus.Test.Fixtures.DuplicateRegisterer
        ])

      assert Enum.any?(results["duplicate_process_name"], fn
               [":my_process", mod1, mod2, _site1, _site2] ->
                 String.contains?(mod1, "DuplicateRegisterer") and
                   String.contains?(mod2, "ProcessRegisterer")

               _ ->
                 false
             end)
    end

    test "a single module's distinct names are not duplicates" do
      skip_without_souffle()

      # ProcessRegisterer registers :my_process and :my_erlang_proc —
      # different names, no conflict.
      results = analyze([Argus.Test.Fixtures.ProcessRegisterer])

      assert results["duplicate_process_name"] == []
    end
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
