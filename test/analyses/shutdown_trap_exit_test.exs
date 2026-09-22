defmodule Argus.Analyses.ShutdownTrapExitTest do
  use ExUnit.Case

  alias Argus.Souffle
  alias Argus.Test.Rows

  defp skip_without_souffle do
    unless Souffle.available?(), do: flunk("souffle not installed")
  end

  defp analyze(modules) do
    assert {:ok, results} = Argus.analyze(modules, :shutdown)
    results
  end

  defp exit_rows(results, kind),
    do: Rows.where(results, :shutdown, "unhandled_exit_signal", kind: kind, drop: [:kind])

  describe "unhandled_exit_signal: no_exit_clause" do
    test "a handle_info that never matches {:EXIT, ...} is reported" do
      skip_without_souffle()

      results =
        analyze([
          Argus.Test.Fixtures.TrapsWithoutExitClause,
          Argus.Test.Fixtures.TrapsWithExitClause
        ])

      mods = Enum.map(exit_rows(results, "no_exit_clause"), fn [mod, _w] -> mod end)

      assert mods == ["Argus.Test.Fixtures.TrapsWithoutExitClause"]

      # Having a handle_info at all satisfies the coarser rule; this one is
      # about which clauses it has.
      assert exit_rows(results, "no_handler") == []
    end
  end

  describe "unhandled_exit_signal: no_handler" do
    test "flags a raw :gen_server that traps exits with no handle_info" do
      skip_without_souffle()

      results = analyze([Argus.Test.Fixtures.RawTrapExit])

      assert Enum.any?(exit_rows(results, "no_handler"), fn [mod, _witness] ->
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

      assert exit_rows(results, "no_handler") == []
    end

    test "does not flag a gen_statem that traps exits" do
      skip_without_souffle()

      # gen_statem delivers {:EXIT, ...} to its state functions, not to a
      # handle_info callback, so the has_handle_info heuristic would
      # false-positive every trapping gen_statem.
      results = analyze([Argus.Test.Fixtures.StatemTrapExit])

      assert exit_rows(results, "no_handler") == []
    end
  end
end
