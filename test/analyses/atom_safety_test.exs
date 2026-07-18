defmodule Argus.Analyses.AtomSafetyTest do
  use ExUnit.Case

  alias Argus.Souffle

  defp skip_without_souffle do
    unless Souffle.available?(), do: flunk("souffle not installed")
  end

  defp analyze(modules) do
    assert {:ok, results} = Argus.analyze(modules, :atom_safety)
    results
  end

  describe "atom_exhaustion_risk" do
    test "flags dynamic atom creation, not to_existing_atom" do
      skip_without_souffle()

      results = analyze([Argus.Test.Fixtures.UnsafeAtomCreation])

      rows = results["atom_exhaustion_risk"]
      funcs = Enum.map(rows, fn [_id, func, _api] -> func end)
      apis = Enum.map(rows, fn [_id, _func, api] -> api end)

      # String.to_atom/1 compiles down to the :erlang.binary_to_atom BIF,
      # so the fixture's String.to_atom call surfaces under that API name.
      assert Enum.any?(funcs, &String.contains?(&1, "to_atom_from_input"))
      assert Enum.any?(apis, &String.contains?(&1, "binary_to_atom"))
      assert Enum.any?(apis, &String.contains?(&1, "list_to_atom"))
      refute Enum.any?(apis, &String.contains?(&1, "existing"))
      refute Enum.any?(funcs, &String.contains?(&1, "existing_atom"))
    end
  end

  describe "unsafe_deserialization_finding" do
    test "flags binary_to_term without :safe, not the :safe variant" do
      skip_without_souffle()

      results = analyze([Argus.Test.Fixtures.UnsafeDeserialization])

      funcs =
        Enum.map(results["unsafe_deserialization_finding"], fn [_id, func, _api] -> func end)

      assert Enum.any?(funcs, &String.contains?(&1, "decode_unsafe"))
      refute Enum.any?(funcs, &String.contains?(&1, "decode_safe"))
    end
  end

  describe "code_injection_risk" do
    test "flags eval and shell-out APIs, not a fully-literal System.cmd" do
      skip_without_souffle()

      results = analyze([Argus.Test.Fixtures.CodeExecution])
      funcs = Enum.map(results["code_injection_risk"], fn [_id, func, _api] -> func end)

      assert Enum.any?(funcs, &String.contains?(&1, "eval"))
      assert Enum.any?(funcs, &String.contains?(&1, "os_cmd"))
      # Dynamic command/args — attacker-influenceable.
      assert Enum.any?(funcs, &String.contains?(&1, "system_cmd"))
      # Literal command and args — nothing dynamic to inject.
      refute Enum.any?(funcs, &String.contains?(&1, "static_system_cmd"))
    end
  end

  describe "safe modules" do
    test "a module using only safe APIs produces no findings" do
      skip_without_souffle()

      results = analyze([Argus.Test.Fixtures.SafeModule])

      assert results["atom_exhaustion_risk"] == []
      assert results["unsafe_deserialization_finding"] == []
      assert results["code_injection_risk"] == []
    end
  end
end
