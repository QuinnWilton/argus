defmodule Argus.Analyses.StartupStartResultTest do
  use ExUnit.Case, async: true
  @moduletag :souffle

  alias Argus.Test.Memo

  defp analyze(modules) do
    assert {:ok, results} = Memo.analyze(modules, :startup)
    results
  end

  describe "ignored_start_result" do
    test "flags an ignored start_link result, not a checked one" do
      results = analyze([Argus.Test.Fixtures.IgnoredResultModule])

      funcs = Enum.map(results["ignored_start_result"], fn [func, _callee] -> func end)

      assert Enum.any?(funcs, &String.contains?(&1, "ignored_start"))
      refute Enum.any?(funcs, &String.contains?(&1, "checked_start"))

      # Returned by a closure: ignored when the library call running it
      # drops what it answers, checked by the caller when it keeps it.
      assert Enum.any?(funcs, &String.contains?(&1, "-each_ignored_start/1-fun-"))
      refute Enum.any?(funcs, &String.contains?(&1, "mapped_checked_start"))

      # Kept by the call running the closure, then lost: dropped by the
      # caller, by an Enum.each closure handing it back, by a helper's
      # caller; or looked at only as truthy (Enum.any?).
      for name <- ~w(mapped_dropped_start comprehension_dropped_start any_ignored_start
                     nested_dropped_start start_all) do
        assert Enum.any?(funcs, &String.contains?(&1, "-#{name}/1-fun-")), name
      end

      # Its elements matched afterwards: checked.
      refute Enum.any?(funcs, &String.contains?(&1, "mapped_matched_start"))

      # Consed onto the list a comprehension or fold builds, the list
      # dropped; matched or handed out, checked.
      for name <- ~w(two_generators_dropped_start filtered_dropped_start reduce_dropped_start) do
        assert Enum.any?(funcs, &String.contains?(&1, "-#{name}/")), name
      end

      for name <- ~w(two_generators_matched_start filtered_returned_start) do
        refute Enum.any?(funcs, &String.contains?(&1, name)), name
      end
    end

    test "matches the delimited function name, not a substring" do
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
      assert {:ok, results} = Argus.Test.Memo.run_rules(facts, :startup)
      results["ignored_start_result"] || []
    end
  end
end
