defmodule Argus.Analyses.FailureWhereisTest do
  use ExUnit.Case, async: true

  alias Argus.Souffle
  alias Argus.Test.Memo
  alias Argus.Test.Rows

  defp skip_without_souffle do
    unless Souffle.available?(), do: flunk("souffle not installed")
  end

  defp analyze(modules) do
    assert {:ok, results} = Memo.analyze(modules, :failure)
    results
  end

  defp whereis(results),
    do: Rows.where(results, :failure, "unchecked_result", api: "Process.whereis", drop: [:api])

  describe "unchecked_result: Process.whereis" do
    test "flags a static-name whereis call site" do
      skip_without_souffle()

      results = analyze([Argus.Test.Fixtures.StaticWhereis])

      assert Enum.any?(whereis(results), fn [func, _id, name] ->
               String.contains?(func, "StaticWhereis:lookup/0") and name == ":my_process"
             end)
    end

    test "a lookup whose nil use is rescued is not flagged; one rescuing else is" do
      skip_without_souffle()

      funcs =
        [Argus.Test.Fixtures.StaticWhereis]
        |> analyze()
        |> whereis()
        |> Enum.map(fn [func | _] -> func |> String.split(":") |> List.last() end)

      refute "memory/0" in funcs, "the ArgumentError rescue takes nil's badarg"
      assert "memory_or_raise/0" in funcs, "a KeyError rescue does not"
    end

    test "does not flag whereis on a runtime-computed name" do
      skip_without_souffle()

      # WhereisModule's lookups take the name as an argument — the rule
      # only speaks about statically-known names.
      results = analyze([Argus.Test.Fixtures.WhereisModule])

      assert whereis(results) == []
    end
  end
end
