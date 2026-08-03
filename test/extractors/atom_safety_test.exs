defmodule Argus.Extractors.AtomSafetyTest do
  use ExUnit.Case, async: true

  alias Argus.Extractors.AtomSafety

  defp disassemble(mod) do
    {:ok, data} = BeamSpy.BeamFile.disassemble(to_string(:code.which(mod)))
    data
  end

  describe "extract/1 — unsafe atom creation" do
    test "detects String.to_atom" do
      facts = AtomSafety.extract(disassemble(Argus.Test.Fixtures.UnsafeAtomCreation))

      assert Map.has_key?(facts, :unsafe_atom_creation)
      rows = facts[:unsafe_atom_creation]

      apis = Enum.map(rows, fn [_, _, api] -> api end)
      assert Enum.any?(apis, &String.contains?(&1, "to_atom"))
    end

    test "detects :erlang.binary_to_atom" do
      facts = AtomSafety.extract(disassemble(Argus.Test.Fixtures.UnsafeAtomCreation))

      rows = facts[:unsafe_atom_creation]
      apis = Enum.map(rows, fn [_, _, api] -> api end)
      assert Enum.any?(apis, &String.contains?(&1, "binary_to_atom"))
    end

    test "detects :erlang.list_to_atom" do
      facts = AtomSafety.extract(disassemble(Argus.Test.Fixtures.UnsafeAtomCreation))

      rows = facts[:unsafe_atom_creation]
      apis = Enum.map(rows, fn [_, _, api] -> api end)
      assert Enum.any?(apis, &String.contains?(&1, "list_to_atom"))
    end
  end

  describe "extract/1 — unsafe deserialization" do
    test "detects binary_to_term/1 as unsafe" do
      facts = AtomSafety.extract(disassemble(Argus.Test.Fixtures.UnsafeDeserialization))

      assert Map.has_key?(facts, :unsafe_deserialization)
      rows = facts[:unsafe_deserialization]

      assert Enum.any?(rows, fn [_, _, api, safety] ->
               String.contains?(api, "binary_to_term/1") and safety == "unsafe"
             end)
    end

    test "records [:safe] as atoms_only, because that is all it is" do
      facts = AtomSafety.extract(disassemble(Argus.Test.Fixtures.UnsafeDeserialization))

      rows = facts[:unsafe_deserialization]

      # OTP's own docs: `safe` prevents new atoms and new EXTERNAL function
      # references, and "does not guarantee that the data is safe for your
      # application". Paginator CVE-2020-15150 is RCE through this option —
      # a base64 cursor decoded to a fun that Enumerable then invoked. The
      # fix was a validating decoder; `safe` was already present.
      assert Enum.any?(rows, fn [_, _, api, safety] ->
               String.contains?(api, "binary_to_term/2") and safety == "atoms_only"
             end)
    end

    test "records a term-walking decoder as validated" do
      facts = AtomSafety.extract(disassemble(Argus.Test.Fixtures.UnsafeDeserialization))

      assert Enum.any?(facts[:unsafe_deserialization], fn [_, _, api, safety] ->
               String.contains?(api, "non_executable_binary_to_term") and safety == "validated"
             end)
    end
  end

  describe "extract/1 — code execution" do
    test "detects Code.eval_string" do
      facts = AtomSafety.extract(disassemble(Argus.Test.Fixtures.CodeExecution))

      assert Map.has_key?(facts, :code_execution)
      rows = facts[:code_execution]
      apis = Enum.map(rows, fn [_, _, api] -> api end)
      assert Enum.any?(apis, &String.contains?(&1, "eval_string"))
    end

    test "detects :os.cmd" do
      facts = AtomSafety.extract(disassemble(Argus.Test.Fixtures.CodeExecution))

      rows = facts[:code_execution]
      apis = Enum.map(rows, fn [_, _, api] -> api end)
      assert Enum.any?(apis, &String.contains?(&1, "cmd"))
    end

    test "detects System.cmd with dynamic args" do
      facts = AtomSafety.extract(disassemble(Argus.Test.Fixtures.CodeExecution))

      rows = facts[:code_execution]
      apis = Enum.map(rows, fn [_, _, api] -> api end)
      assert Enum.any?(apis, &String.contains?(&1, "System.cmd"))
    end

    test "skips System.cmd with static command and args" do
      facts = AtomSafety.extract(disassemble(Argus.Test.Fixtures.CodeExecution))

      rows = facts[:code_execution] || []

      # static_system_cmd calls System.cmd("echo", ["hello"]) — no injection vector.
      static_cmds =
        Enum.filter(rows, fn [_id, func, _api] ->
          String.contains?(func, "static_system_cmd")
        end)

      assert static_cmds == []
    end
  end

  describe "extract/1 — clean module" do
    test "returns empty for plain module" do
      facts = AtomSafety.extract(disassemble(Argus.Test.Fixtures.PlainModule))
      assert facts == %{}
    end
  end

  describe "integration with extract pipeline" do
    test "extractor is usable via Pipeline.extract/2" do
      assert {:ok, facts} =
               Argus.Pipeline.extract(
                 [Argus.Test.Fixtures.UnsafeAtomCreation],
                 extractors: [AtomSafety]
               )

      assert Map.has_key?(facts, :unsafe_atom_creation)
    end
  end
end
