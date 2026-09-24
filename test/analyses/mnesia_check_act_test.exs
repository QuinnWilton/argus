defmodule Argus.Analyses.MnesiaCheckActTest do
  use ExUnit.Case, async: true

  alias Argus.Analyses.Races
  alias Argus.Souffle
  alias Argus.Test.Fixtures.CheckThenAct, as: C

  defp skip_without_souffle do
    unless Souffle.available?(), do: flunk("souffle not installed")
  end

  defp races(modules) do
    {:ok, results} = Argus.analyze(modules, :races)

    for [_mod, func, table, key, read, write, _op] <- results["mnesia_check_act"],
        do: {short(func), table, key, short(read), short(write)}
  end

  defp short(id), do: id |> String.split("#") |> hd() |> String.split(":") |> List.last()

  describe "mnesia_check_act" do
    test "a dirty read, one added, a dirty write of the same record" do
      skip_without_souffle()

      assert races([C.MnesiaCounter]) == [
               {"bump/1", ":counters", "0", "bump/1", "bump/1"}
             ]
    end

    test "the record the read found, updated in place and written back" do
      skip_without_souffle()
      assert [{"bump/1", ":counters", "0", "bump/1", "bump/1"}] = races([C.MnesiaPutElem])
      assert [{"bump/1", ":counters", "0", "bump/1", "bump/1"}] = races([C.MnesiaRecordUpdate])
    end

    test "the record the read found, updated by a helper's put_elem pipeline" do
      skip_without_souffle()

      assert [{"record_bet/2", ":betting_stats", "0", "record_bet/2", "record_bet/2"}] =
               races([C.MnesiaHelperUpdate])
    end

    test "an update in place that sets the key writes another record" do
      skip_without_souffle()
      assert races([C.MnesiaPutElemKey]) == []
    end

    test "deleting the record the read found expired is not a lost update" do
      skip_without_souffle()
      assert races([C.MnesiaExpire]) == []
    end

    test "the delete is reported on a table the program writes back from a read" do
      skip_without_souffle()
      found = races([C.MnesiaExpireCounted])
      assert Enum.any?(found, &match?({"fetch/2", ":uses", _, _, _}, &1))
      assert Enum.any?(found, &match?({"use/2", ":uses", _, _, _}, &1))
    end

    test "the read and the write in helpers, the read's result handed to the write" do
      skip_without_souffle()

      assert [{"bump/1", ":counters", "0", "get/1", "put/2"} | _] =
               rows = races([C.MnesiaHelpers])

      # One row per put/2 clause's write.
      assert length(rows) == 2
    end

    test "a key built at runtime is the same key when one definition feeds both" do
      skip_without_souffle()

      assert [{"put/3", ":records", key, "put/3", "put/3"}] = races([C.MnesiaComputedKey])
      assert key =~ "MnesiaComputedKey:put/3#"
    end

    test "a key another definition makes is not the read's key" do
      skip_without_souffle()
      assert races([C.MnesiaJoinedKey]) == []
    end

    test "a read-modify-write in a dirty activity" do
      skip_without_souffle()

      assert [
               {"-bump/1-fun-0-/1", ":counters", "0", _, _},
               {"-bump_in_activity/1-fun-0-/1", ":counters", "0", _, _} | _
             ] =
               races([C.MnesiaAsyncDirty]) |> Enum.uniq_by(&elem(&1, 0)) |> Enum.sort()
    end

    test "a transaction, the atomic counter, and a different record are quiet" do
      skip_without_souffle()
      assert races([C.MnesiaTransaction, C.MnesiaUpdateCounter, C.MnesiaOtherKey]) == []
    end

    test "a record handed to a helper as elements and whole meets where the caller builds it" do
      skip_without_souffle()

      assert [{"create/2", ":entities", _key, "do_insert_new/3", "do_insert_new/3"}] =
               races([C.MnesiaRecordHelper])
    end

    test "elements of one record and another record whole are not the same record" do
      skip_without_souffle()
      assert races([C.MnesiaRecordOther]) == []
    end

    test "a match on the key and a lookup by an index are reads" do
      skip_without_souffle()
      assert [{"claim/2", ":claims", _, "claim/2", "claim/2"}] = races([C.MnesiaMatchThenWrite])

      assert [{"register/2", ":users", _, "register/2", "register/2"}] =
               races([C.MnesiaIndexThenWrite])
    end

    test "a cluster lock every writer takes serializes the pair" do
      skip_without_souffle()
      assert races([C.MnesiaGlobalLock]) == []
    end

    test "one writer outside the lock unserializes it" do
      skip_without_souffle()

      assert [{"-bump/1-fun-0-/1", ":locked_counters", _, _, _}] =
               races([C.MnesiaGlobalLock, C.MnesiaLockBypass])
    end

    test "an idempotent default whose decision stays inside is not reported" do
      skip_without_souffle()
      assert races([C.MnesiaEnsureDefault]) == []
    end

    test "a claim whose decision the caller gets is reported" do
      skip_without_souffle()
      assert [{"claim/1", ":prefs_claims", _, _, _}] = races([C.MnesiaClaim])
    end

    test "a table only its owner's callbacks write has one writer" do
      skip_without_souffle()
      assert races([C.MnesiaOwner]) == []
    end

    test "another writer through a helper handed the record, in a transaction, or counting" do
      skip_without_souffle()

      for other <- [C.MnesiaOwnerResetter, C.MnesiaOwnerTxnResetter, C.MnesiaOwnerCounter] do
        assert [{"handle_call/3", ":owned_counters", _, _, _}] = races([C.MnesiaOwner, other]),
               "#{inspect(other)}"
      end
    end

    test "a delete on a table written back through a record helper, or counted into" do
      skip_without_souffle()

      assert Enum.any?(
               races([C.MnesiaExpireSaved]),
               &match?({"fetch/2", ":saved_uses", _, _, _}, &1)
             )

      assert [{"fetch/2", ":hits", _, _, _}] = races([C.MnesiaExpireHits])
    end
  end

  describe "finding" do
    test "anchors the dirty write, relates the dirty read, and names the transaction" do
      row = ["M", "M:bump/1", ":counters", "0", "M:get/1#6", "M:bump/1#27", "dirty_write"]
      f = Races.finding(:mnesia_check_act, row)

      assert f.severity == :warning
      assert f.title =~ "Mnesia"
      assert f.detail =~ "dirty read in M.get/1"
      assert [%{label: "the dirty read it depends on"}] = f.related
      assert Enum.any?(f.help, &(&1 =~ "transaction"))
      assert Enum.any?(f.help, &(&1 =~ "dirty_update_counter"))
    end

    test "names a delete as a delete" do
      row = ["M", "M:fetch/2", ":uses", "0", "M:fetch/2#6", "M:fetch/2#27", "dirty_delete"]
      f = Races.finding(:mnesia_check_act, row)

      assert f.detail =~ "deletes it with dirty_delete"
      refute f.detail =~ "dirty write"
      assert f.at_label =~ "dirty delete"
    end
  end
end
