defmodule Argus.Analyses.StartupStartResultTest do
  use ExUnit.Case

  alias Argus.Souffle

  defp skip_without_souffle do
    unless Souffle.available?(), do: flunk("souffle not installed")
  end

  defp analyze(modules) do
    assert {:ok, results} = Argus.analyze(modules, :startup)
    results
  end

  describe "ignored_start_result" do
    test "flags an ignored start_link result, not a checked one" do
      skip_without_souffle()

      results = analyze([Argus.Test.Fixtures.IgnoredResultModule])

      funcs = Enum.map(results["ignored_start_result"], fn [func, _callee] -> func end)

      assert Enum.any?(funcs, &String.contains?(&1, "ignored_start"))
      refute Enum.any?(funcs, &String.contains?(&1, "checked_start"))
    end

    test "matches the delimited function name, not a substring" do
      skip_without_souffle()

      # Hand-authored facts: a callee named restart_link must not match
      # ".start_link/" — the name is delimited by "." and "/" in the
      # rendered callee.
      base = %{
        ignored_error_result: [
          ["M:a/0#1", "M:a/0", "MyPool.restart_link/1"],
          ["M:b/0#1", "M:b/0", "GenServer.start_link/3"]
        ]
      }

      assert [["M:b/0", "GenServer.start_link/3"]] = ignored_start_rows(base)
    end

    defp ignored_start_rows(facts) do
      dir =
        Path.join(
          System.tmp_dir!(),
          "startup_test_#{:erlang.unique_integer([:positive])}"
        )

      File.mkdir_p!(dir)

      try do
        :ok = Argus.Pipeline.write_facts(facts, dir)
        assert {:ok, results} = Argus.Analysis.run_rules(dir, :startup)
        results["ignored_start_result"] || []
      after
        File.rm_rf(dir)
      end
    end
  end
end
