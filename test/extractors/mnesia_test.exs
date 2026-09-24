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

  test "a key built at runtime is named by what it is built of" do
    [{_, "dirty_read", _, _, {"tuple", read_key}}, {_, "dirty_write", _, _, {"tuple", write_key}}] =
      ops(C.MnesiaComputedKey) |> Enum.sort_by(&elem(&1, 1))

    assert read_key == write_key
    # {String.downcase(name), type}: the call that made the first element, and the parameter.
    assert read_key =~ ~r/^\{local .*MnesiaComputedKey:put\/3#\d+, param 1\}$/
  end

  test "a key two definitions reach is not named" do
    keys = for {_, op, _, _, key} <- ops(C.MnesiaJoinedKey), do: {op, key}

    assert {"dirty_write", {"dynamic", ""}} in keys
    assert {"dirty_read", {"tuple", "{param 0, literal :a}"}} = List.keyfind(keys, "dirty_read", 0)
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
