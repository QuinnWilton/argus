defmodule Argus.Analyses.FailureWhereisTest do
  use ExUnit.Case, async: true
  @moduletag :flowlog

  alias Argus.Test.Memo
  alias Argus.Test.Rows

  defp analyze(modules) do
    assert {:ok, results} = Memo.analyze(modules, :failure)
    results
  end

  defp whereis(results),
    do: Rows.where(results, :failure, "unchecked_result", api: "Process.whereis", drop: [:api])

  describe "unchecked_result: Process.whereis" do
    test "flags a static-name whereis call site" do
      results = analyze([Argus.Test.Fixtures.StaticWhereis])

      assert Enum.any?(whereis(results), fn [func, _id, name] ->
               String.contains?(func, "StaticWhereis:lookup/0") and name == ":my_process"
             end)
    end

    test "a lookup whose nil use is rescued is not flagged; one rescuing else is" do
      funcs =
        [Argus.Test.Fixtures.StaticWhereis]
        |> analyze()
        |> whereis()
        |> Enum.map(fn [func | _] -> func |> String.split(":") |> List.last() end)

      refute "memory/0" in funcs, "the ArgumentError rescue takes nil's badarg"
      assert "memory_or_raise/0" in funcs, "a KeyError rescue does not"
      assert "memory_and_config/0" in funcs, "a rescue around other code does not"
      assert "memory_catching_exit/0" in funcs, "a catch of exits does not"
      refute "raw_memory/0" in funcs, "a rescue around every call to the function takes it"
    end

    test "a returned lookup is judged at its callers, and one compared with a pid decides" do
      funcs =
        [
          Argus.Test.Fixtures.FailureWhereisReturned,
          Argus.Test.Fixtures.FailureWhereisReturnedUsed
        ]
        |> analyze()
        |> whereis()
        |> Enum.map(fn [func, _id, name] -> {func |> String.split(".") |> List.last(), name} end)
        |> Enum.sort()

      # A cast to nil drops the message, a caller's nil test checks it, a
      # comparison with the group leader or self() decides on it; a send
      # to nil raises, and so does one of two callers' sends.
      assert funcs == [
               {"FailureWhereisReturnedUsed:metrics/0", ":failure_metrics"},
               {"FailureWhereisReturnedUsed:same?/0", ":failure_a"},
               {"FailureWhereisReturnedUsed:same?/0", ":failure_b"},
               {"FailureWhereisReturnedUsed:sink/0", ":failure_sink"}
             ]
    end

    test "does not flag whereis on a runtime-computed name" do
      # WhereisModule's lookups take the name as an argument — the rule
      # only speaks about statically-known names.
      results = analyze([Argus.Test.Fixtures.WhereisModule])

      assert whereis(results) == []
    end
  end
end
