defmodule Argus.Analyses.Padl2010RaceTest do
  @moduledoc """
  Every example in Christakis and Sagonas, "Static Detection of Race
  Conditions in Erlang" (PADL 2010), and the whereis-then-unregister
  warning Dialyzer's implementation of it added. The fixtures in
  `test/fixtures/erl/` keep the paper's code.
  """
  use ExUnit.Case, async: true

  alias Argus.Souffle
  alias Argus.Test.Batch

  # Every test reads its fixtures' rows from one solve of them all
  # (`Argus.Test.Batch`; ARGUS_VERIFY_BATCH=1 checks each slice against
  # a solve of its own).
  @batched [
    :padl2010_proc_reg,
    :padl2010_registered,
    :dialyzer_whereis_unregister,
    :padl2010_ets_inc,
    :padl2010_time_stamp,
    :padl2010_snmp_shadow_table,
    :padl2010_higher_order,
    :padl2010_loop
  ]

  setup_all do
    %{batch: Batch.solve(:races, [@batched])}
  end

  defp skip_without_souffle do
    unless Souffle.available?(), do: flunk("souffle not installed")
  end

  defp rows(%{batch: batch}, modules, relation) do
    {:ok, results} = Batch.analyze(batch, modules)
    results[relation]
  end

  # "Mod:fun/1#4" and "Mod:fun/1" both read as "fun/1".
  defp fa(id), do: id |> String.split("#") |> hd() |> String.split(":") |> List.last()

  defp registry(ctx, modules) do
    for [_mod, func, lookup, act_api, _key_source, key, check, act] <-
          rows(ctx, modules, "registry_race"),
        do: {fa(func), lookup, act_api, key, fa(check), fa(act)}
  end

  describe "Sect. 3.1, the process registry" do
    test "Fig. 1: proc_reg/1 registers the name its whereis found free", ctx do
      skip_without_souffle()

      assert registry(ctx, [:padl2010_proc_reg]) == [
               {"proc_reg/1", "whereis", "register", "0", "proc_reg/1", "proc_reg/1"}
             ]
    end

    test "deciding with registered() is the same race on every name", ctx do
      skip_without_souffle()

      assert [{"register_if_free/1", "registered", "register", "", _, _}] =
               registry(ctx, [:padl2010_registered])
    end

    test "Dialyzer's second registry warning: whereis, then unregister", ctx do
      skip_without_souffle()

      assert registry(ctx, [:dialyzer_whereis_unregister]) == [
               {"stop/1", "whereis", "unregister", "0", "stop/1", "stop/1"}
             ]
    end
  end

  describe "Sect. 3.2, ETS" do
    test "Fig. 2 (left): both inserts of ets_inc/2, on the unnamed public table its closure is handed",
         ctx do
      skip_without_souffle()

      rows = rows(ctx, [:padl2010_ets_inc], "ets_check_act")

      assert [{"ets_inc/2", ":some_tab_name", ":some_key"}] =
               rows
               |> Enum.map(fn [_, f, name, key, _, _] -> {fa(f), name, key} end)
               |> Enum.uniq()

      assert length(rows) == 2
    end
  end

  describe "Sect. 3.3, Mnesia" do
    test "Fig. 2 (right): the dirty write after the case depends on the dirty read through NRef",
         ctx do
      skip_without_souffle()

      assert [
               [
                 ":padl2010_time_stamp",
                 func,
                 ":time_stamp",
                 ":ref_count",
                 _read,
                 _write,
                 _op,
                 "lost_update"
               ]
             ] = rows(ctx, [:padl2010_time_stamp], "mnesia_check_act")

      assert fa(func) == "create_time_stamp_table/0"
    end

    test "the snmp_shadow_table code the figure was taken from: dirty_read/1 on a {table, key}",
         ctx do
      skip_without_souffle()

      assert [[_, func, ":time_stamp", ":ref_count", _read, _write, _op, "lost_update"]] =
               rows(ctx, [:padl2010_snmp_shadow_table], "mnesia_check_act")

      assert fa(func) == "create_time_stamp_table/0"
    end
  end

  describe "Sect. 4.2, paths across functions" do
    test "an unknown higher-order call is not followed, as in the paper's evaluation", ctx do
      skip_without_souffle()

      races = registry(ctx, [:padl2010_higher_order])
      refute Enum.any?(races, fn {func, _, _, _, _, _} -> func in ["foo/3", "call_foo/0"] end)
    end

    test "a statically known call is followed into the function that registers", ctx do
      skip_without_souffle()

      assert {"known/1", "whereis", "register", "0", "known/1", "register_self/1"} in registry(
               ctx,
               [
                 :padl2010_higher_order
               ]
             )
    end

    test "names that cannot be shown equal are filtered, as the paper's atom sets are", ctx do
      skip_without_souffle()

      refute Enum.any?(
               registry(ctx, [:padl2010_higher_order]),
               &match?({"unrelated/2", _, _, _, _, _}, &1)
             )
    end

    test "a loop: the read decides the write of the next iteration", ctx do
      skip_without_souffle()

      rows = rows(ctx, [:padl2010_loop], "ets_check_act")

      assert [{"tick/2", ":loop_hits", ":hits"}] =
               rows
               |> Enum.map(fn [_, f, name, key, _, _] -> {fa(f), name, key} end)
               |> Enum.uniq()

      # Both inserts sit before the lookup in the loop body.
      assert length(rows) == 2

      for [_, _, _, _, read, write] <- rows do
        assert index(write) < index(read)
      end
    end
  end

  describe "quiet where the loser's outcome is taken" do
    test "unregister's badarg caught", ctx do
      skip_without_souffle()

      refute Enum.any?(
               registry(ctx, [:dialyzer_whereis_unregister]),
               &match?({"stop_caught/1", _, _, _, _, _}, &1)
             )
    end
  end

  defp index(id), do: id |> String.split("#") |> List.last() |> String.to_integer()
end
