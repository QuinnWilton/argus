defmodule Argus.Analyses.ErrorHandlingTest do
  use ExUnit.Case

  alias Argus.Souffle

  defp skip_without_souffle do
    unless Souffle.available?(), do: flunk("souffle not installed")
  end

  defp analyze(modules) do
    assert {:ok, results} = Argus.analyze(modules, :error_handling)
    results
  end

  describe "swallowed_error" do
    test "flags a bare rescue, not a filtered one" do
      skip_without_souffle()

      results =
        analyze([Argus.Test.Fixtures.BareRescue, Argus.Test.Fixtures.FilteredRescue])

      funcs = Enum.map(results["swallowed_error"], fn [func] -> func end)

      assert Enum.any?(funcs, &String.contains?(&1, "BareRescue"))
      refute Enum.any?(funcs, &String.contains?(&1, "FilteredRescue"))
    end
  end

  describe "trap_exit_without_handler" do
    test "flags a raw :gen_server that traps exits with no handle_info" do
      skip_without_souffle()

      results = analyze([Argus.Test.Fixtures.RawTrapExit])

      assert Enum.any?(results["trap_exit_without_handler"], fn [mod, _witness] ->
               String.contains?(mod, "RawTrapExit")
             end)
    end

    test "cannot fire for `use GenServer` modules (known false negative)" do
      skip_without_souffle()

      # TrapExitModule traps exits and defines no handle_info of its own,
      # but `use GenServer` compiles a default handle_info/2 into every
      # module — so the has_handle_info(mod) heuristic is always
      # satisfied and the rule is vacuous for idiomatic Elixir GenServers
      # even when no clause matches {:EXIT, ...}. Making this real needs
      # clause-level pattern facts, not function existence. This test
      # pins the limitation so a future fix flips it consciously.
      results = analyze([Argus.Test.Fixtures.TrapExitModule])

      assert results["trap_exit_without_handler"] == []
    end
  end

  describe "exit_in_callback" do
    test "flags Process.exit inside a GenServer callback" do
      skip_without_souffle()

      results = analyze([Argus.Test.Fixtures.ExitingServer])

      assert Enum.any?(results["exit_in_callback"], fn [func, _target] ->
               String.contains?(func, "ExitingServer:handle_cast/2")
             end)
    end

    test "does not flag Process.exit outside process callbacks" do
      skip_without_souffle()

      # ExitCaller is a plain module — exit calls there are not callback
      # hazards.
      results = analyze([Argus.Test.Fixtures.ExitCaller])

      assert results["exit_in_callback"] == []
    end
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
          "error_handling_test_#{:erlang.unique_integer([:positive])}"
        )

      File.mkdir_p!(dir)

      try do
        :ok = Argus.Pipeline.write_facts(facts, dir)
        assert {:ok, results} = Argus.Analysis.run_rules(dir, :error_handling)
        results["ignored_start_result"] || []
      after
        File.rm_rf(dir)
      end
    end
  end
end
