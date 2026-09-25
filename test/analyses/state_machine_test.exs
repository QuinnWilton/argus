defmodule Argus.Analyses.StateMachineTest do
  use ExUnit.Case, async: true

  alias Argus.Souffle
  alias Argus.Test.Memo

  defp skip_without_souffle do
    unless Souffle.available?(), do: flunk("souffle not installed")
  end

  defp states(rows), do: rows |> Enum.map(fn [_mod, state, _site] -> state end) |> Enum.uniq()

  defp analyze(modules) do
    assert {:ok, results} = Memo.analyze(modules, :state_machine)
    results
  end

  describe "unreachable_state / terminal_without_stop" do
    test "flags a dead state that no transition targets and isn't initial" do
      skip_without_souffle()

      results = analyze([Argus.Test.Fixtures.OrphanStateStatem])

      # :abandoned returns a real action (so it's a state) but nothing
      # targets it and it isn't the init state.
      assert Enum.any?(results["unreachable_state"], fn [mod, state, _site] ->
               String.contains?(mod, "OrphanStateStatem") and state == "abandoned"
             end)

      # :idle is the init state (read from init/1) and :running is a
      # transition target — neither is unreachable even though :idle has
      # no incoming edge of its own.
      refute Enum.any?(results["unreachable_state"], fn [_mod, state, _site] ->
               state in ["idle", "running"]
             end)
    end

    test "a well-formed machine produces no structural findings" do
      skip_without_souffle()

      results = analyze([Argus.Test.Fixtures.SimpleStatem])

      assert results["unreachable_state"] == []
      assert results["terminal_without_stop"] == []
    end

    test "a machine with no extracted transitions produces no findings" do
      skip_without_souffle()

      # DelegatingStatem's state functions delegate to a helper, so their
      # own bodies contain no gen_statem action return — they aren't even
      # registered as states. Nothing to flag.
      results = analyze([Argus.Test.Fixtures.DelegatingStatem])

      assert results["unreachable_state"] == []
      assert results["terminal_without_stop"] == []
    end

    test "a state's own keep_state is no way in and no way out" do
      skip_without_souffle()

      results = analyze([Argus.Test.Fixtures.ClosedForeverStatem])

      # :closed is entered from :open and only ever keeps its state.
      assert states(results["terminal_without_stop"]) == ["closed"]
      # :abandoned's catch-all keeps the state: a self-loop, not an entry.
      assert states(results["unreachable_state"]) == ["abandoned"]
    end

    test "a state whose function only delegates is judged by what it delegates to" do
      skip_without_souffle()

      results = analyze([Argus.Test.Fixtures.DelegatedAbyssStatem])

      assert [[_mod, "abyss", site]] = results["terminal_without_stop"]
      assert site =~ ":abyss/3"
    end

    test "a transition a helper builds is a way in and a way out" do
      skip_without_souffle()

      results = analyze([Argus.Test.Fixtures.HelperTransitionStatem])

      # :disconnected is entered only by disconnect/2's return, :connected
      # leaves only through it, and :waiting returns another module's
      # answer in one clause.
      assert results["unreachable_state"] == []
      assert results["terminal_without_stop"] == []
    end

    test "a machine that never leaves its initial state has no terminal state" do
      skip_without_souffle()

      results = analyze([Argus.Test.Fixtures.RestingStatem])

      assert results["unreachable_state"] == []
      assert results["terminal_without_stop"] == []
    end

    test "handle_event_function modules produce no structural findings" do
      skip_without_souffle()

      # In handle_event_function mode there is a single handle_event/4 and
      # states are data values; the structural rules are scoped out. This
      # is the DBConnection.Connection shape (init {:ok, :no_state, _}).
      results = analyze([Argus.Test.Fixtures.HandleEventStatem])

      assert results["unreachable_state"] == []
      assert results["terminal_without_stop"] == []
    end
  end
end
