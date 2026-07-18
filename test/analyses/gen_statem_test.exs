defmodule Argus.Analyses.GenStatemTest do
  use ExUnit.Case

  alias Argus.Souffle

  defp skip_without_souffle do
    unless Souffle.available?(), do: flunk("souffle not installed")
  end

  defp analyze(modules) do
    assert {:ok, results} = Argus.analyze(modules, :gen_statem)
    results
  end

  describe "unreachable_state / terminal_without_stop" do
    test "flags a dead state with no transitions in either direction" do
      skip_without_souffle()

      results = analyze([Argus.Test.Fixtures.OrphanStateStatem])

      # :abandoned is never targeted and never transitions out.
      assert Enum.any?(results["unreachable_state"], fn [mod, state, _site] ->
               String.contains?(mod, "OrphanStateStatem") and state == "abandoned"
             end)

      assert Enum.any?(results["terminal_without_stop"], fn [mod, state, _site] ->
               String.contains?(mod, "OrphanStateStatem") and state == "abandoned"
             end)

      # The live idle <-> running cycle is not flagged.
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

      # DelegatingStatem's state functions all delegate to a helper, so
      # the extractor sees states but no transitions. Before the
      # extraction-confidence gate, every state was flagged both
      # unreachable and terminal — pure extraction-gap noise.
      results = analyze([Argus.Test.Fixtures.DelegatingStatem])

      assert results["unreachable_state"] == []
      assert results["terminal_without_stop"] == []
    end
  end
end
