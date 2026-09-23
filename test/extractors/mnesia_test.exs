defmodule Argus.Extractors.MnesiaTest do
  use ExUnit.Case, async: true

  alias Argus.Extractors.Mnesia
  alias Argus.Test.Fixtures.CheckThenAct, as: C

  defp ops(module) do
    {:ok, facts} = Argus.Pipeline.extract([module], extractors: [Mnesia])

    for [_id, func, op, kind, ts, t, ks, k] <- Map.get(facts, :mnesia_op, []),
        do: {func |> String.split(":") |> List.last(), op, kind, {ts, t}, {ks, k}}
  end

  test "dirty_read/2 and a record written with dirty_write/1: table and key from the record" do
    assert Enum.sort(ops(:padl2010_time_stamp)) == [
             {"create_time_stamp_table/0", "dirty_read", "read", {"literal", ":time_stamp"},
              {"literal", ":ref_count"}},
             {"create_time_stamp_table/0", "dirty_write", "write", {"literal", ":time_stamp"},
              {"literal", ":ref_count"}}
           ]
  end

  test "dirty_read/1 on a {table, key} literal" do
    assert {"create_time_stamp_table/0", "dirty_read", "read", {"literal", ":time_stamp"},
            {"literal", ":ref_count"}} in ops(:padl2010_snmp_shadow_table)
  end

  test "a key that is the function's parameter, in the tuple and in the record" do
    rows = ops(C.MnesiaHelpers)

    assert {"get/1", "dirty_read", "read", {"literal", ":counters"}, {"param", "0"}} in rows

    assert {"put/2", "dirty_write", "write", {"literal", ":counters"}, {"param", "0"}} in rows
  end

  test "the transactional and the atomic operations are not dirty reads or writes" do
    assert ops(C.MnesiaTransaction) == []
    assert ops(C.MnesiaUpdateCounter) == []
  end

  test "site?/1 is exactly the dirty reads and writes" do
    assert Mnesia.site?({:mnesia, :dirty_read, 2})
    assert Mnesia.site?({:mnesia, :dirty_delete_object, 1})
    refute Mnesia.site?({:mnesia, :dirty_update_counter, 3})
    refute Mnesia.site?({:mnesia, :read, 2})
    refute Mnesia.site?({:ets, :lookup, 2})
  end
end
