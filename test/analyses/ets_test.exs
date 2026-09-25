defmodule Argus.Analyses.EtsTest do
  use ExUnit.Case, async: true

  alias Argus.Souffle
  alias Argus.Test.Memo

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

      assert {:ok, results} = Memo.analyze(modules, :ets)

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

    test "a table a non-process behaviour's init makes is its caller's" do
      skip_without_souffle()

      modules = [Argus.Test.Fixtures.EtsStrategy, Argus.Test.Fixtures.EtsStrategyImpl]
      assert {:ok, results} = Memo.analyze(modules, :ets)

      # Positive: EtsOwner, a GenServer, fires above.
      assert Map.get(results, "ets_unprotected_owner", []) == []
    end

    test "suppresses unprotected_owner for permanent supervisor children" do
      skip_without_souffle()

      modules = [
        Argus.Test.Fixtures.EtsOwner,
        Argus.Test.Fixtures.EtsPermanentSupervisor
      ]

      assert {:ok, results} = Memo.analyze(modules, :ets)

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

      assert {:ok, results} = Memo.analyze(modules, :ets)

      # EtsOwner is a permanent child under an Erlang-style supervisor.
      unprotected = results["ets_unprotected_owner"]

      refute Enum.any?(unprotected, fn [_name, mod] ->
               mod == "Argus.Test.Fixtures.EtsOwner"
             end)
    end

    test "an OTP tuple child spec is a supervisor's child as a map spec is" do
      skip_without_souffle()

      owner = fn modules ->
        {:ok, results} = Memo.analyze(modules, :ets)
        for [_name, ":tuple_spec_first" | _] <- results["ets_unprotected_owner"], do: :reported
      end

      # Alone, the owner's table dies with it; under tuple_spec_sup, whose
      # `{first, {tuple_spec_first, start_link, []}, permanent, ...}` spec
      # restarts it, the restart recreates the table.
      assert owner.([:tuple_spec_first]) == [:reported]
      assert owner.([:tuple_spec_first, :tuple_spec_sup]) == []
    end

    test "suppresses unprotected_owner for Application modules" do
      skip_without_souffle()

      modules = [
        Argus.Test.Fixtures.EtsApplicationOwner
      ]

      assert {:ok, results} = Memo.analyze(modules, :ets)

      # Application modules live for the entire app — not a real risk.
      unprotected = results["ets_unprotected_owner"]

      refute Enum.any?(unprotected, fn [_name, mod] ->
               mod == "Argus.Test.Fixtures.EtsApplicationOwner"
             end)
    end

    test "EtsOwner without supervisor still fires unprotected_owner" do
      skip_without_souffle()

      modules = [Argus.Test.Fixtures.EtsOwner]

      assert {:ok, results} = Memo.analyze(modules, :ets)

      unprotected = results["ets_unprotected_owner"]

      assert Enum.any?(unprotected, fn [_name, mod, _site] ->
               mod == "Argus.Test.Fixtures.EtsOwner"
             end)
    end
  end

  describe "a table's owner" do
    test "is the process on whose stack :ets.new runs, not the module that spells it" do
      skip_without_souffle()

      modules = [
        Argus.Test.Fixtures.EtsTableHelper,
        Argus.Test.Fixtures.EtsHelperOwner,
        Argus.Test.Fixtures.EtsClientCreated
      ]

      assert {:ok, results} = Memo.analyze(modules, :ets)

      # A helper module's named table, made by a server's init/1, is the
      # server's; the unnamed one it hands back is the server's data, and
      # a server module's client function makes its caller's table, no
      # process of the program calling it.
      assert [[":helper_made", "Argus.Test.Fixtures.EtsHelperOwner", site]] =
               results["ets_unprotected_owner"]

      assert site =~ "EtsTableHelper:create/0#"
      assert results["ets_unnamed_in_process"] == []
    end

    test "a table its own module makes in its process is still its own" do
      skip_without_souffle()

      assert {:ok, results} = Memo.analyze([Argus.Test.Fixtures.EtsUnnamed], :ets)

      assert [[":anon_table", "Argus.Test.Fixtures.EtsUnnamed", _]] =
               results["ets_unnamed_in_process"]

      assert [[":anon_table", "Argus.Test.Fixtures.EtsUnnamed", _]] =
               results["ets_unprotected_owner"]
    end

    test "a helper's table two processes may make is one finding" do
      skip_without_souffle()

      modules = [
        Argus.Test.Fixtures.EtsTableHelper,
        Argus.Test.Fixtures.EtsHelperOwner,
        Argus.Test.Fixtures.EtsSecondHelperOwner
      ]

      assert {:ok, results} = Memo.analyze(modules, :ets)
      rows = results["ets_unprotected_owner"]
      assert length(rows) == 2

      relation =
        Enum.find(Argus.Analyses.Ets.output_relations(), &(&1.name == :ets_unprotected_owner))

      assert [[":helper_made", "Argus.Test.Fixtures.EtsHelperOwner", _]] =
               Argus.Findings.dedupe_rows(relation, rows)
    end
  end

  describe "ets_write_only_table" do
    test "a named table with inserts and no deletes is reported; bounded and warm caches are not" do
      skip_without_souffle()

      modules = [
        Argus.Test.Fixtures.EtsGrowOnly,
        Argus.Test.Fixtures.EtsBounded,
        Argus.Test.Fixtures.EtsWarmCache
      ]

      assert {:ok, results} = Memo.analyze(modules, :ets)

      assert [[":audit_log", "Argus.Test.Fixtures.EtsGrowOnly", site]] =
               results["ets_write_only_table"]

      assert site =~ "EtsGrowOnly:init/1#"
    end

    test "a set table written only under literal keys holds one row per key" do
      skip_without_souffle()

      modules = [Argus.Test.Fixtures.EtsSettings, Argus.Test.Fixtures.EtsSettingsBag]
      assert {:ok, results} = Memo.analyze(modules, :ets)

      assert [[":settings_bag", "Argus.Test.Fixtures.EtsSettingsBag", _site]] =
               results["ets_write_only_table"],
             "a bag keeps every insert under the same key; a set overwrites it"
    end

    test "a keypos of 1 spelled out is the default; another keys the table elsewhere" do
      skip_without_souffle()

      modules = [Argus.Test.Fixtures.EtsSettingsKeypos1, Argus.Test.Fixtures.EtsSettingsKeypos2]
      assert {:ok, results} = Memo.analyze(modules, :ets)

      assert [[":settings_keypos2", "Argus.Test.Fixtures.EtsSettingsKeypos2", _site]] =
               results["ets_write_only_table"]
    end
  end
end
