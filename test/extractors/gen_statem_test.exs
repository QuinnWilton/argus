defmodule Argus.Extractors.GenStatemTest do
  use ExUnit.Case, async: true

  alias Argus.Extractors.GenStatem

  defp disassemble(mod) do
    {:ok, data} = BeamSpy.BeamFile.disassemble(to_string(:code.which(mod)))
    data
  end

  describe "extract/1 — state_functions mode" do
    test "detects gen_statem module" do
      facts = GenStatem.extract(disassemble(Argus.Test.Fixtures.SimpleStatem))

      assert Map.has_key?(facts, :statem_module)
      rows = facts[:statem_module]
      assert length(rows) == 1

      [mod, mode] = hd(rows)
      assert String.contains?(mod, "SimpleStatem")
      assert mode == "state_functions"
    end

    test "detects states" do
      facts = GenStatem.extract(disassemble(Argus.Test.Fixtures.SimpleStatem))

      assert Map.has_key?(facts, :statem_state)
      rows = facts[:statem_state]
      states = Enum.map(rows, fn [_, state, _site] -> state end) |> Enum.uniq()

      assert "idle" in states
      assert "running" in states
    end

    test "registers only exported functions as states" do
      facts = GenStatem.extract(disassemble(Argus.Test.Fixtures.PrivateHelperStatem))

      states = Enum.map(facts[:statem_state], fn [_, state, _site] -> state end)

      # Real states.
      assert "idle" in states
      assert "running" in states

      # A private arity-3 helper is not a state.
      refute "normalize" in states

      # An exported, arity-3, action-returning helper that a state calls
      # directly is not a state (gen_statem never calls a state locally).
      refute "finalize" in states

      # Compiler-lifted closures (private arity-3 top-level functions with
      # mangled names) are not states.
      refute Enum.any?(states, &String.starts_with?(&1, "-"))
    end

    test "detects transitions" do
      facts = GenStatem.extract(disassemble(Argus.Test.Fixtures.SimpleStatem))

      assert Map.has_key?(facts, :statem_transition)
      rows = facts[:statem_transition]

      # idle -> running.
      assert Enum.any?(rows, fn [_, from, _, to] ->
               from == "idle" and to == "running"
             end)

      # running -> idle.
      assert Enum.any?(rows, fn [_, from, _, to] ->
               from == "running" and to == "idle"
             end)
    end

    test "detects stop transition" do
      facts = GenStatem.extract(disassemble(Argus.Test.Fixtures.SimpleStatem))

      rows = facts[:statem_transition]

      assert Enum.any?(rows, fn [_, from, _, to] ->
               from == "running" and to == "stop"
             end)
    end
  end

  describe "extract/1 — timeouts" do
    test "detects state_timeout in timeout statem" do
      facts = GenStatem.extract(disassemble(Argus.Test.Fixtures.TimeoutStatem))

      timeouts = Map.get(facts, :statem_timeout, [])

      assert Enum.any?(timeouts, fn [_, state, type, _value] ->
               state == "waiting" and type == "state_timeout"
             end)
    end
  end

  describe "extract/1 — clean module" do
    test "returns empty for non-statem module" do
      facts = GenStatem.extract(disassemble(Argus.Test.Fixtures.PlainModule))
      assert facts == %{}
    end
  end

  describe "integration with extract pipeline" do
    test "extractor is usable via Pipeline.extract/2" do
      assert {:ok, facts} =
               Argus.Pipeline.extract(
                 [Argus.Test.Fixtures.SimpleStatem],
                 extractors: [GenStatem]
               )

      assert Map.has_key?(facts, :statem_module)
    end
  end
end
