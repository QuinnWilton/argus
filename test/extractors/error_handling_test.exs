defmodule Argus.Extractors.ErrorHandlingTest do
  use ExUnit.Case, async: true

  alias Argus.Extractors.ErrorHandling

  defp disassemble(mod) do
    {:ok, data} = BeamSpy.BeamFile.disassemble(to_string(:code.which(mod)))
    data
  end

  describe "extract/1 — bare rescue" do
    test "detects bare catch that swallows all exceptions" do
      facts = ErrorHandling.extract(disassemble(Argus.Test.Fixtures.BareRescue))

      assert Map.has_key?(facts, :bare_rescue)
      rows = facts[:bare_rescue]
      assert length(rows) >= 1
    end

    test "does not flag rescue with exception class filtering" do
      facts = ErrorHandling.extract(disassemble(Argus.Test.Fixtures.FilteredRescue))

      bare = Map.get(facts, :bare_rescue, [])
      assert bare == []
    end
  end

  describe "extract/1 — trap_exit" do
    test "detects Process.flag(:trap_exit, true)" do
      facts = ErrorHandling.extract(disassemble(Argus.Test.Fixtures.TrapExitModule))

      assert Map.has_key?(facts, :trap_exit)
      rows = facts[:trap_exit]
      assert length(rows) >= 1

      mods = Enum.map(rows, fn [_, mod] -> mod end)
      assert Enum.any?(mods, &String.contains?(&1, "TrapExitModule"))
    end
  end

  describe "extract/1 — exit calls" do
    test "detects Process.exit/2" do
      facts = ErrorHandling.extract(disassemble(Argus.Test.Fixtures.ExitCaller))

      assert Map.has_key?(facts, :exit_call)
      rows = facts[:exit_call]
      assert length(rows) >= 1
    end

    test "detects :erlang.exit/1" do
      facts = ErrorHandling.extract(disassemble(Argus.Test.Fixtures.ExitCaller))

      rows = facts[:exit_call]

      assert Enum.any?(rows, fn [_, func, _] ->
               String.contains?(func, "exit_self")
             end)
    end
  end

  describe "extract/1 — ignored error results" do
    test "detects ignored GenServer.start_link result" do
      facts = ErrorHandling.extract(disassemble(Argus.Test.Fixtures.IgnoredResultModule))

      ignored = Map.get(facts, :ignored_error_result, [])

      assert Enum.any?(ignored, fn [_, func, callee] ->
               String.contains?(func, "ignored_start") and
                 String.contains?(callee, "start_link")
             end)
    end

    test "does not flag checked GenServer.start_link result" do
      facts = ErrorHandling.extract(disassemble(Argus.Test.Fixtures.IgnoredResultModule))

      ignored = Map.get(facts, :ignored_error_result, [])

      refute Enum.any?(ignored, fn [_, func, _] ->
               String.contains?(func, "checked_start")
             end)
    end
  end

  describe "extract/1 — clean module" do
    test "returns empty for plain module" do
      facts = ErrorHandling.extract(disassemble(Argus.Test.Fixtures.PlainModule))
      assert facts == %{}
    end
  end

  describe "integration with extract pipeline" do
    test "extractor is usable via Pipeline.extract/2" do
      assert {:ok, facts} =
               Argus.Pipeline.extract(
                 [Argus.Test.Fixtures.TrapExitModule],
                 extractors: [ErrorHandling]
               )

      assert Map.has_key?(facts, :trap_exit)
    end
  end
end
