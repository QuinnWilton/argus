defmodule Argus.Analyses.EtsTest do
  use ExUnit.Case, async: true
  @moduletag :souffle

  alias Argus.Test.Memo

  describe "ets.dl" do
    test "detects ETS anti-patterns" do
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
      modules = [Argus.Test.Fixtures.EtsStrategy, Argus.Test.Fixtures.EtsStrategyImpl]
      assert {:ok, results} = Memo.analyze(modules, :ets)

      # Positive: EtsOwner, a GenServer, fires above.
      assert Map.get(results, "ets_unprotected_owner", []) == []
    end

    test "suppresses unprotected_owner for permanent supervisor children" do
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

    test "a private table, and one the application's root supervisor holds, die with nothing" do
      owners = fn modules ->
        {:ok, results} = Memo.analyze(modules, :ets)

        results["ets_unprotected_owner"]
        |> Enum.map(fn [_name, mod, _site] -> mod end)
        |> Enum.sort()
      end

      # EtsOwner's public table is reported beside the private one;
      # branch_sup, which no application starts, beside root_app_sup.
      assert owners.([Argus.Test.Fixtures.EtsOwner, Argus.Test.Fixtures.EtsPrivateOwner]) ==
               ["Argus.Test.Fixtures.EtsOwner"]

      assert owners.([:root_app, :root_app_sup, :branch_sup]) == [":branch_sup"]
    end

    test "a table another process can read, or whose owner may restart, still dies with it" do
      tables = fn modules ->
        {:ok, results} = Memo.analyze(modules, :ets)

        results["ets_unprotected_owner"]
        |> Enum.map(fn [name, _mod, _site] -> name end)
        |> Enum.sort()
      end

      # Protected by default, options from the caller, a public table beside
      # a private one: each is readable by another process.
      assert tables.([
               Argus.Test.Fixtures.EtsProtectedOwner,
               Argus.Test.Fixtures.EtsOptionsFromArgOwner,
               Argus.Test.Fixtures.EtsPrivateAndPublicOwner
             ]) == [":configured_cache", ":owner_shared", ":protected_cache"]

      # A temporary or transient tuple child is not restarted by its
      # supervisor every time. (One a helper's spec names by a parameter is
      # read with the call's argument bound: tuple_param_owner is a
      # permanent child, and quiet.)
      assert tables.([
               :tuple_restart_sup,
               :tuple_temp_owner,
               :tuple_transient_owner,
               :tuple_param_owner
             ]) == [
               ":tuple_temp_owner_tab",
               ":tuple_transient_owner_tab"
             ]

      # A worker an application's start/2 starts, a root supervisor another
      # tree also starts as a transient child, one a start/2 that is no
      # Application's callback starts: none dies only with the application.
      assert tables.([
               :worker_app,
               :worker_owner,
               :dual_app,
               :dual_sup,
               :outer_sup,
               :fake_app,
               :fake_root_sup
             ]) == [":dual_snapshot", ":fake_root_snapshot", ":worker_owner_tab"]
    end

    test "suppresses unprotected_owner for Application modules" do
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
      assert {:ok, results} = Memo.analyze([Argus.Test.Fixtures.EtsUnnamed], :ets)

      assert [[":anon_table", "Argus.Test.Fixtures.EtsUnnamed", _]] =
               results["ets_unnamed_in_process"]

      assert [[":anon_table", "Argus.Test.Fixtures.EtsUnnamed", _]] =
               results["ets_unprotected_owner"]
    end

    test "a helper's table two processes may make is one finding" do
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

  describe "on the one table identity" do
    test "two unnamed tables made under one atom are two tables" do
      modules = [Argus.Test.Fixtures.EtsTwinUnnamed, Argus.Test.Fixtures.EtsTwinUnnamedOther]
      assert {:ok, results} = Memo.analyze(modules, :ets)

      for relation <- ~w(ets_missing_read_concurrency ets_missing_write_concurrency
                         ets_ordered_set_contention) do
        assert Map.get(results, relation, []) == [], relation
      end
    end

    test "an unnamed table handed by its reference to another module is shared with it" do
      modules = [Argus.Test.Fixtures.EtsHandedQueue, Argus.Test.Fixtures.EtsHandedQueueReader]
      assert {:ok, results} = Memo.analyze(modules, :ets)

      for relation <- ~w(ets_missing_read_concurrency ets_missing_write_concurrency) do
        assert [[":handed_queue", "Argus.Test.Fixtures.EtsHandedQueue", _]] =
                 results[relation],
               relation
      end

      assert [[":handed_queue", _, _, _]] = results["ets_ordered_set_contention"]
    end

    test "a removal of another table the server keeps does not remove the log's rows" do
      assert {:ok, results} = Memo.analyze([Argus.Test.Fixtures.EtsGrowsBesideScratch], :ets)

      assert [[":scratch_log", "Argus.Test.Fixtures.EtsGrowsBesideScratch", _]] =
               results["ets_write_only_table"]
    end

    test "a removal of a table the callers hand in may be the log" do
      assert {:ok, results} = Memo.analyze([Argus.Test.Fixtures.EtsGrowsBesideHanded], :ets)
      assert Map.get(results, "ets_write_only_table", []) == []
    end

    test "a named table a helper makes under the name it is handed is read outside its owner" do
      assert {:ok, results} = Memo.analyze([Argus.Test.Fixtures.EtsHelperNamedOwner], :ets)

      assert [[":helper_acl", "Argus.Test.Fixtures.EtsHelperNamedOwner", reader, _, _]] =
               results["ets_read_outside_owner"]

      assert reader =~ "lookup/1"
    end
  end

  describe "ets_write_only_table" do
    test "a named table with inserts and no deletes is reported; bounded and warm caches are not" do
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
      modules = [Argus.Test.Fixtures.EtsSettings, Argus.Test.Fixtures.EtsSettingsBag]
      assert {:ok, results} = Memo.analyze(modules, :ets)

      assert [[":settings_bag", "Argus.Test.Fixtures.EtsSettingsBag", _site]] =
               results["ets_write_only_table"],
             "a bag keeps every insert under the same key; a set overwrites it"
    end

    test "a keypos of 1 spelled out is the default; another keys the table elsewhere" do
      modules = [Argus.Test.Fixtures.EtsSettingsKeypos1, Argus.Test.Fixtures.EtsSettingsKeypos2]
      assert {:ok, results} = Memo.analyze(modules, :ets)

      assert [[":settings_keypos2", "Argus.Test.Fixtures.EtsSettingsKeypos2", _site]] =
               results["ets_write_only_table"]
    end
  end
end
