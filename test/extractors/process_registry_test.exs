defmodule Argus.Extractors.ProcessRegistryTest do
  use ExUnit.Case, async: true

  alias Argus.Extractors.ProcessRegistry

  defp disassemble(mod) do
    {:ok, data} = BeamSpy.BeamFile.disassemble(to_string(:code.which(mod)))
    data
  end

  describe "extract/1 — process registration" do
    test "detects Process.register" do
      facts = ProcessRegistry.extract(disassemble(Argus.Test.Fixtures.ProcessRegisterer))

      assert Map.has_key?(facts, :process_register)
      rows = facts[:process_register]

      assert Enum.any?(rows, fn [_, _, name, method] ->
               name == ":my_process" and method == "register"
             end)
    end

    test "detects :erlang.register" do
      facts = ProcessRegistry.extract(disassemble(Argus.Test.Fixtures.ProcessRegisterer))

      rows = facts[:process_register]

      assert Enum.any?(rows, fn [_, _, name, method] ->
               name == ":my_erlang_proc" and method == "register"
             end)
    end
  end

  describe "extract/1 — whereis" do
    test "detects Process.whereis" do
      facts = ProcessRegistry.extract(disassemble(Argus.Test.Fixtures.WhereisModule))

      assert Map.has_key?(facts, :whereis_call)
      rows = facts[:whereis_call]
      assert length(rows) >= 1
    end

    test "detects :erlang.whereis" do
      facts = ProcessRegistry.extract(disassemble(Argus.Test.Fixtures.WhereisModule))

      rows = facts[:whereis_call]
      assert length(rows) >= 2
    end
  end

  describe "extract/1 — Registry operations" do
    test "detects Registry.register" do
      facts = ProcessRegistry.extract(disassemble(Argus.Test.Fixtures.RegistryUser))

      assert Map.has_key?(facts, :registry_op)
      rows = facts[:registry_op]

      assert Enum.any?(rows, fn [_, _, _, op, _] -> op == "register" end)
    end

    test "detects Registry.lookup" do
      facts = ProcessRegistry.extract(disassemble(Argus.Test.Fixtures.RegistryUser))

      rows = facts[:registry_op]
      assert Enum.any?(rows, fn [_, _, _, op, _] -> op == "lookup" end)
    end
  end

  describe "extract/1 — clean module" do
    test "returns empty for plain module" do
      facts = ProcessRegistry.extract(disassemble(Argus.Test.Fixtures.PlainModule))
      assert facts == %{}
    end
  end

  describe "extract/1 — named_process" do
    test "emits named_process for direct register/2 with the enclosing module" do
      facts = ProcessRegistry.extract(disassemble(Argus.Test.Fixtures.ProcessRegisterer))

      assert Map.has_key?(facts, :named_process)
      rows = facts[:named_process]

      # Direct Process.register(self(), :my_process) — emit
      # named_process(<enclosing module>, :my_process).
      assert Enum.any?(rows, fn [mod, name] ->
               mod == "Argus.Test.Fixtures.ProcessRegisterer" and name == ":my_process"
             end)
    end
  end

  describe "integration with extract pipeline" do
    test "extractor is usable via Pipeline.extract/2" do
      assert {:ok, facts} =
               Argus.Pipeline.extract(
                 [Argus.Test.Fixtures.ProcessRegisterer],
                 extractors: [ProcessRegistry]
               )

      assert Map.has_key?(facts, :process_register)
    end
  end
end
