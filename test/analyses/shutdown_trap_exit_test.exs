defmodule Argus.Analyses.ShutdownTrapExitTest do
  use ExUnit.Case, async: true
  @moduletag :souffle

  alias Argus.Test.Memo
  alias Argus.Test.Rows

  defp analyze(modules) do
    assert {:ok, results} = Memo.analyze(modules, :shutdown)
    results
  end

  defp exit_rows(results, kind),
    do: Rows.where(results, :shutdown, "unhandled_exit_signal", kind: kind, drop: [:kind])

  describe "unhandled_exit_signal: no_exit_clause" do
    test "a handle_info that never matches {:EXIT, ...} is reported" do
      results =
        analyze([
          Argus.Test.Fixtures.TrapsWithoutExitClause,
          Argus.Test.Fixtures.TrapsWithExitClause,
          Argus.Test.Fixtures.SpawnsATrapper
        ])

      mods = Enum.map(exit_rows(results, "no_exit_clause"), fn [mod, _w] -> mod end)

      assert mods == ["Argus.Test.Fixtures.TrapsWithoutExitClause"],
             "a trap_exit in a fun the server spawns is that process's, not the server's"

      # Having a handle_info at all satisfies the coarser rule; this one is
      # about which clauses it has.
      assert exit_rows(results, "no_handler") == []
    end
  end

  describe "unhandled_exit_signal: the process that traps" do
    test "a trap a helper sets is the calling server's, not the helper module's" do
      results =
        analyze([
          Argus.Test.Fixtures.TrapHelper,
          Argus.Test.Fixtures.TrapsThroughHelper,
          Argus.Test.Fixtures.CleansUpThroughHelperTrap
        ])

      assert [["Argus.Test.Fixtures.TrapsThroughHelper", witness]] =
               exit_rows(results, "no_exit_clause")

      assert witness =~ "TrapHelper:enable/0"

      # TrapHelper runs no process: no handle_info is missing from it.
      assert exit_rows(results, "no_handler") == []

      # The server that traps through the helper is not "never traps".
      refute Enum.any?(
               Map.get(results, "cleanup_defect", []),
               &match?([_mod, _b, "never_runs" | _], &1)
             )
    end
  end

  describe "a proc_lib start that enters the server loop" do
    test "traps for the server it becomes" do
      results =
        analyze([
          Argus.Test.Fixtures.CleansUpEnteringLoop,
          Argus.Test.Fixtures.LeaksEnteringLoop,
          Argus.Test.Fixtures.LeaksBesideAnotherLoop,
          Argus.Test.Fixtures.OtherLoop
        ])

      never_runs =
        for [mod, _b, "never_runs" | _] <- Map.get(results, "cleanup_defect", []),
            uniq: true,
            do: mod

      # init/1 runs in the process proc_lib starts, and enter_loop makes
      # that process the server: its trap is the server's. A trap before
      # entering another module's loop is that server's, not this one's.
      assert never_runs == [
               "Argus.Test.Fixtures.LeaksBesideAnotherLoop",
               "Argus.Test.Fixtures.LeaksEnteringLoop"
             ]

      assert exit_rows(results, "no_exit_clause") == []
    end
  end

  describe "a trap the process clears, or sets on one path" do
    test "a trap init/1 clears before it returns leaves the server not trapping" do
      results =
        analyze([
          Argus.Test.Fixtures.CleansUpAfterScopedTrap,
          Argus.Test.Fixtures.CleansUpOnOptionTrap
        ])

      never_runs =
        for [mod, _b, "never_runs" | _] <- Map.get(results, "cleanup_defect", []),
            uniq: true,
            do: mod

      # Cleared: a supervisor's shutdown skips terminate/2, and no
      # {:EXIT, ...} arrives for handle_info/2 to miss.
      assert never_runs == ["Argus.Test.Fixtures.CleansUpAfterScopedTrap"]
      assert exit_rows(results, "no_exit_clause") == []

      # Set on one path: a trap any path sets counts, and terminate/2 runs.
      refute "Argus.Test.Fixtures.CleansUpOnOptionTrap" in never_runs
    end
  end

  describe "unhandled_exit_signal: no_handler" do
    test "flags a raw :gen_server that traps exits with no handle_info" do
      results = analyze([Argus.Test.Fixtures.RawTrapExit])

      assert Enum.any?(exit_rows(results, "no_handler"), fn [mod, _witness] ->
               String.contains?(mod, "RawTrapExit")
             end)
    end

    test "cannot fire for `use GenServer` modules (known false negative)" do
      # TrapExitModule traps exits and defines no handle_info of its own,
      # but `use GenServer` compiles a default handle_info/2 into every
      # module — so the has_handle_info(mod) heuristic is always
      # satisfied and the rule is vacuous for idiomatic Elixir GenServers
      # even when no clause matches {:EXIT, ...}. Making this real needs
      # clause-level pattern facts, not function existence. This test
      # pins the limitation so a future fix flips it consciously.
      results = analyze([Argus.Test.Fixtures.TrapExitModule])

      assert exit_rows(results, "no_handler") == []
    end

    test "a module that runs no gen_server misses no handle_info" do
      # Positive: RawTrapExit (above) is a gen_server with no handle_info.
      results = analyze([Argus.Test.Fixtures.TrapsForItsCaller])
      assert exit_rows(results, "no_handler") == []
    end

    test "does not flag a gen_statem that traps exits" do
      # gen_statem delivers {:EXIT, ...} to its state functions, not to a
      # handle_info callback, so the has_handle_info heuristic would
      # false-positive every trapping gen_statem.
      results = analyze([Argus.Test.Fixtures.StatemTrapExit])

      assert exit_rows(results, "no_handler") == []
    end
  end
end
