defmodule Argus.Analyses.EtsTest do
  use ExUnit.Case

  alias Argus.Souffle

  defp skip_without_souffle do
    unless Souffle.available?(), do: flunk("souffle not installed")
  end

  describe "ets.dl" do
    test "detects ETS anti-patterns" do
      skip_without_souffle()

      modules = [
        Argus.Test.Fixtures.EtsOwner,
        Argus.Test.Fixtures.EtsReader,
        Argus.Test.Fixtures.EtsWriter,
        Argus.Test.Fixtures.EtsUnnamed,
        Argus.Test.Fixtures.EtsWellConfigured,
        Argus.Test.Fixtures.EtsParamTable
      ]

      assert {:ok, results} = Argus.analyze(modules, :ets)

      # Informational relations are no longer output.
      refute Map.has_key?(results, "ets_owner_process")
      refute Map.has_key?(results, "ets_reader_module")
      refute Map.has_key?(results, "ets_writer_module")

      # EtsOwner without a supervisor still fires as unprotected.
      assert Map.has_key?(results, "ets_unprotected_owner")
      unprotected = results["ets_unprotected_owner"]

      assert Enum.any?(unprotected, fn [_name, mod, _site] ->
               mod == "Argus.Test.Fixtures.EtsOwner"
             end)
    end

    test "suppresses unprotected_owner for permanent supervisor children" do
      skip_without_souffle()

      modules = [
        Argus.Test.Fixtures.EtsOwner,
        Argus.Test.Fixtures.EtsPermanentSupervisor
      ]

      assert {:ok, results} = Argus.analyze(modules, :ets)

      # EtsOwner is a permanent child — table recreated on restart.
      unprotected = results["ets_unprotected_owner"]

      refute Enum.any?(unprotected, fn [_name, mod] ->
               mod == "Argus.Test.Fixtures.EtsOwner"
             end)
    end

    test "suppresses unprotected_owner for Erlang-style supervisor children" do
      skip_without_souffle()

      modules = [
        Argus.Test.Fixtures.EtsOwner,
        Argus.Test.Fixtures.ErlangStyleEtsSupervisor
      ]

      assert {:ok, results} = Argus.analyze(modules, :ets)

      # EtsOwner is a permanent child under an Erlang-style supervisor.
      unprotected = results["ets_unprotected_owner"]

      refute Enum.any?(unprotected, fn [_name, mod] ->
               mod == "Argus.Test.Fixtures.EtsOwner"
             end)
    end

    test "suppresses unprotected_owner for Application modules" do
      skip_without_souffle()

      modules = [
        Argus.Test.Fixtures.EtsApplicationOwner
      ]

      assert {:ok, results} = Argus.analyze(modules, :ets)

      # Application modules live for the entire app — not a real risk.
      unprotected = results["ets_unprotected_owner"]

      refute Enum.any?(unprotected, fn [_name, mod] ->
               mod == "Argus.Test.Fixtures.EtsApplicationOwner"
             end)
    end

    test "EtsOwner without supervisor still fires unprotected_owner" do
      skip_without_souffle()

      modules = [Argus.Test.Fixtures.EtsOwner]

      assert {:ok, results} = Argus.analyze(modules, :ets)

      unprotected = results["ets_unprotected_owner"]

      assert Enum.any?(unprotected, fn [_name, mod, _site] ->
               mod == "Argus.Test.Fixtures.EtsOwner"
             end)
    end
  end
end
