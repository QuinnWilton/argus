defmodule Argus.Analyses.MnesiaCheckActTest do
  use ExUnit.Case, async: true

  alias Argus.Analyses.Races
  alias Argus.Test.Batch
  alias Argus.Test.Fixtures.CheckThenAct, as: C
  alias Argus.Test.Fixtures.RacesExposureClaim, as: Claims
  alias Argus.Test.Memo

  # Every test reads its fixtures' rows from one solve of them all
  # (`Argus.Test.Batch`; ARGUS_VERIFY_BATCH=1 checks each slice against
  # a solve of its own).
  @batched [
    C.MnesiaCounter,
    C.MnesiaPutElem,
    C.MnesiaRecordUpdate,
    C.MnesiaHelperUpdate,
    C.MnesiaPutElemKey,
    C.MnesiaExpire,
    C.MnesiaCaptchaCheck,
    C.MnesiaExpireCounted,
    C.MnesiaHelpers,
    C.MnesiaComputedKey,
    C.MnesiaJoinedKey,
    C.MnesiaAsyncDirty,
    C.MnesiaTransaction,
    C.MnesiaUpdateCounter,
    C.MnesiaOtherKey,
    C.MnesiaRecordHelper,
    C.MnesiaRecordOther,
    C.MnesiaMatchThenWrite,
    C.MnesiaIndexThenWrite,
    C.MnesiaGlobalLock,
    C.MnesiaEnsureDefault,
    C.MnesiaClaim,
    C.MnesiaOwner,
    C.MnesiaExpireSaved,
    C.MnesiaExpireHits,
    C.MnesiaCachedTotals,
    C.MnesiaShadowedRead,
    C.MnesiaUniqueQuiet,
    C.MnesiaGetOrDefault,
    C.MnesiaTwoBranches,
    C.MnesiaSharedRead,
    C.MnesiaChargeOnce,
    Claims.MnesiaRefresh,
    Claims.MnesiaTakeFree
  ]

  setup_all do
    %{batch: Batch.solve(:races, [@batched])}
  end

  # A set that shares a module with another test's is about what the
  # modules do together: it is solved on its own (`:alone`), and the
  # batch holds only disjoint sets.
  defp solve(:alone, modules), do: Memo.analyze(modules, :races)
  defp solve(%{batch: batch}, modules), do: Batch.analyze(batch, modules)

  defp races(source, modules) do
    {:ok, results} = solve(source, modules)

    for [_mod, func, table, key, read, write, _op, _kind] <- results["mnesia_check_act"],
        do: {short(func), table, key, short(read), short(write)}
  end

  # The finding each row is: where the pair meets, its read and write
  # (instruction IDs, unabridged) and its kind.
  defp kinds(source, modules) do
    {:ok, results} = solve(source, modules)

    for [_mod, func, _table, _key, read, write, _op, kind] <- results["mnesia_check_act"],
        do: {short(func), read, write, kind}
  end

  defp frames(source, modules) do
    {:ok, results} = solve(source, modules)
    for [write, role, site, _func] <- results["mnesia_race_frame"], do: {write, role, site}
  end

  defp short(id), do: id |> String.split("#") |> hd() |> String.split(":") |> List.last()

  describe "mnesia_check_act" do
    @describetag :flowlog

    test "a dirty read, one added, a dirty write of the same record", ctx do
      assert races(ctx, [C.MnesiaCounter]) == [
               {"bump/1", ":counters", "0", "bump/1", "bump/1"}
             ]
    end

    test "the record the read found, updated in place and written back", ctx do
      assert [{"bump/1", ":counters", "0", "bump/1", "bump/1"}] = races(ctx, [C.MnesiaPutElem])

      assert [{"bump/1", ":counters", "0", "bump/1", "bump/1"}] =
               races(ctx, [C.MnesiaRecordUpdate])
    end

    test "the record the read found, updated by a helper's put_elem pipeline", ctx do
      assert [{"record_bet/2", ":betting_stats", "0", "record_bet/2", "record_bet/2"}] =
               races(ctx, [C.MnesiaHelperUpdate])
    end

    test "an update in place that sets the key writes another record", ctx do
      assert races(ctx, [C.MnesiaPutElemKey]) == []
    end

    test "deleting the record the read found expired is not a lost update", ctx do
      assert races(ctx, [C.MnesiaExpire]) == []
      # A delete whose decision also tells another process, in a helper.
      assert [_ | _] = races(ctx, [C.MnesiaCaptchaCheck])
    end

    test "the delete is reported on a table the program writes back from a read", ctx do
      found = races(ctx, [C.MnesiaExpireCounted])
      assert Enum.any?(found, &match?({"fetch/2", ":uses", _, _, _}, &1))
      assert Enum.any?(found, &match?({"use/2", ":uses", _, _, _}, &1))
    end

    test "the read and the write in helpers, the read's result handed to the write", ctx do
      # put/2's `[]` clause writes 1, its other clause n + 1: one race,
      # reported where it loses an update, the fill its other branch.
      assert [{"bump/1", ":counters", "0", "get/1", "put/2"}] = races(ctx, [C.MnesiaHelpers])
      assert [{"bump/1", _, _, "lost_update"}] = kinds(ctx, [C.MnesiaHelpers])
    end

    test "a key built at runtime is the same key when one definition feeds both", ctx do
      assert [{"put/3", ":records", key, "put/3", "put/3"}] = races(ctx, [C.MnesiaComputedKey])
      assert key =~ "MnesiaComputedKey:put/3#"
    end

    test "a key another definition makes is not the read's key", ctx do
      assert races(ctx, [C.MnesiaJoinedKey]) == []
    end

    test "a read-modify-write in a dirty activity", ctx do
      assert [
               {"-bump/1-fun-0-/1", ":counters", "0", _, _},
               {"-bump_in_activity/1-fun-0-/1", ":counters", "0", _, _} | _
             ] =
               races(ctx, [C.MnesiaAsyncDirty]) |> Enum.uniq_by(&elem(&1, 0)) |> Enum.sort()
    end

    test "a transaction, the atomic counter, and a different record are quiet", ctx do
      assert races(ctx, [C.MnesiaTransaction, C.MnesiaUpdateCounter, C.MnesiaOtherKey]) == []
    end

    test "a record handed to a helper as elements and whole meets where the caller builds it",
         ctx do
      assert [{"create/2", ":entities", _key, "do_insert_new/3", "do_insert_new/3"}] =
               races(ctx, [C.MnesiaRecordHelper])
    end

    test "elements of one record and another record whole are not the same record", ctx do
      assert races(ctx, [C.MnesiaRecordOther]) == []
    end

    test "a match on the key and a lookup by an index are reads", ctx do
      assert [{"claim/2", ":claims", _, "claim/2", "claim/2"}] =
               races(ctx, [C.MnesiaMatchThenWrite])

      assert [{"register/2", ":users", _, "register/2", "register/2"}] =
               races(ctx, [C.MnesiaIndexThenWrite])
    end

    test "a cluster lock every writer takes serializes the pair", ctx do
      assert races(ctx, [C.MnesiaGlobalLock]) == []
    end

    test "one writer outside the lock unserializes it" do
      assert [{"-bump/1-fun-0-/1", ":locked_counters", _, _, _}] =
               races(:alone, [C.MnesiaGlobalLock, C.MnesiaLockBypass])
    end

    test "an idempotent default whose decision stays inside is not reported", ctx do
      assert races(ctx, [C.MnesiaEnsureDefault]) == []
    end

    test "a claim whose decision the caller gets is reported", ctx do
      assert [{"claim/1", ":prefs_claims", _, _, _}] = races(ctx, [C.MnesiaClaim])
    end

    test "a table only its owner's callbacks write has one writer", ctx do
      assert races(ctx, [C.MnesiaOwner]) == []
    end

    test "another writer through a helper handed the record, in a transaction, or counting" do
      for other <- [C.MnesiaOwnerResetter, C.MnesiaOwnerTxnResetter, C.MnesiaOwnerCounter] do
        assert [{"handle_call/3", ":owned_counters", _, _, _}] =
                 races(:alone, [C.MnesiaOwner, other]),
               "#{inspect(other)}"
      end
    end

    test "each kind: a lost update, a guard, a claim, a delete, a search", ctx do
      assert [{_, _, _, "lost_update"}] = kinds(ctx, [C.MnesiaCounter])
      assert [{_, _, _, "guarded"}] = kinds(ctx, [C.MnesiaComputedKey])
      assert [{_, _, _, "claim"}] = kinds(ctx, [C.MnesiaClaim])
      assert [{_, _, _, "claim"}] = kinds(ctx, [C.MnesiaRecordHelper])
      assert [{_, _, _, "unique"}] = kinds(ctx, [C.MnesiaIndexThenWrite])

      assert Enum.any?(
               kinds(ctx, [C.MnesiaExpireCounted]),
               &match?({"fetch/2", _, _, "delete"}, &1)
             )
    end

    test "fills fanning in to one write are one finding, the weakest", ctx do
      found = kinds(ctx, [C.MnesiaCachedTotals])

      # The save/2 write, once, for get_total/1's or get_parts/1's fill;
      # update_a/1's and update_b/1's refresh through it is the other
      # branch of their own write-backs.
      assert [{meet, _, save, "fill"}] = Enum.filter(found, &(elem(&1, 3) == "fill"))
      assert meet in ["get_total/1", "get_parts/1"]
      assert save =~ "save/2#"

      assert found
             |> Enum.filter(&(elem(&1, 3) == "lost_update"))
             |> Enum.map(&elem(&1, 0))
             |> Enum.sort() == ["update_a/2", "update_b/2"]

      # The other getter's read is a frame of the fill.
      reads = for {^save, "read", site} <- frames(ctx, [C.MnesiaCachedTotals]), do: short(site)
      assert Enum.any?(reads, &(&1 in ["get_total/1", "get_parts/1"]))
    end

    test "a write is judged by the read beside it, not by one further up", ctx do
      found = kinds(ctx, [C.MnesiaShadowedRead])

      # set_balance/2's own read decides both of its writes; deduct/2's
      # read reaches them too, and is a frame of the finding, not its read.
      assert [{"set_balance/2", read, write, "lost_update"}] = found
      assert short(read) == "set_balance/2"
      assert short(write) == "set_balance/2"

      assert Enum.any?(
               frames(ctx, [C.MnesiaShadowedRead]),
               &match?({^write, "read", _}, &1)
             )
    end

    test "a read two functions share is ranked where it meets each write", ctx do
      found = kinds(ctx, [C.MnesiaSharedRead])

      # use/2's write-back does not make fetch/2's delete a weaker branch.
      assert Enum.any?(found, &match?({"use/2", _, _, "lost_update"}, &1))
      assert Enum.any?(found, &match?({"fetch/2", _, _, "delete"}, &1))
    end

    test "a marker whose decision also charges decides more than a fill", ctx do
      # The two writes are on one path, to two tables: not an upsert's
      # branches, and the charge is more than the marker.
      assert [{"charge_once/2", _, _, "decides_more"}] = kinds(ctx, [C.MnesiaChargeOnce])
    end

    test "a search that found nothing decides an insert that is never harmless", ctx do
      assert [{"record/2", _, _, "unique"}] = kinds(ctx, [C.MnesiaUniqueQuiet])
    end

    test "a write only where the read found the record is no claim", ctx do
      refute Enum.any?(kinds(ctx, [Claims.MnesiaRefresh]), &(elem(&1, 3) == "claim"))
    end

    test "a found record taken by what it holds is still a claim", ctx do
      assert [{"take/2", _, _, "claim"}] = kinds(ctx, [Claims.MnesiaTakeFree])
    end

    test "a get-or-create answers with the record: a fill, not a claim", ctx do
      assert Enum.any?(kinds(ctx, [C.MnesiaGetOrDefault]), &match?({"get/1", _, _, "fill"}, &1))
      refute Enum.any?(kinds(ctx, [C.MnesiaGetOrDefault]), &(elem(&1, 3) == "claim"))
    end

    test "two write-backs of one read are one finding, the second a frame", ctx do
      assert [{"deduct/2", _, first, "lost_update"}] = kinds(ctx, [C.MnesiaTwoBranches])

      assert [{^first, "also_writes", second}] =
               Enum.filter(frames(ctx, [C.MnesiaTwoBranches]), &(elem(&1, 1) == "also_writes"))

      assert second != first
    end

    test "a delete on a table written back through a record helper, or counted into", ctx do
      assert Enum.any?(
               races(ctx, [C.MnesiaExpireSaved]),
               &match?({"fetch/2", ":saved_uses", _, _, _}, &1)
             )

      assert [{"fetch/2", ":hits", _, _, _}] = races(ctx, [C.MnesiaExpireHits])
    end
  end

  describe "finding" do
    test "anchors the dirty write, relates the dirty read, and names the transaction" do
      row = [
        "M",
        "M:bump/1",
        ":counters",
        "0",
        "M:get/1#6",
        "M:bump/1#27",
        "dirty_write",
        "lost_update"
      ]

      f = Races.finding(:mnesia_check_act, row)

      assert f.severity == :warning
      assert f.title =~ "Mnesia"
      assert f.detail =~ "dirty read in M.get/1"
      assert f.detail =~ "made of what it read"
      assert [%{label: "the dirty read it depends on"}] = f.related
      assert Enum.any?(f.help, &(&1 =~ "transaction"))
      assert Enum.any?(f.help, &(&1 =~ "dirty_update_counter"))
    end

    test "names a delete as a delete" do
      row = [
        "M",
        "M:fetch/2",
        ":uses",
        "0",
        "M:fetch/2#6",
        "M:fetch/2#27",
        "dirty_delete",
        "delete"
      ]

      f = Races.finding(:mnesia_check_act, row)

      assert f.detail =~ "deletes it with dirty_delete"
      refute f.detail =~ "dirty write"
      assert f.at_label =~ "dirty delete"
    end

    test "a search then an insert has its own title" do
      row = [
        "M",
        "M:add/2",
        ":earnings",
        "any",
        "M:add/2#6",
        "M:add/2#27",
        "dirty_write",
        "unique"
      ]

      f = Races.finding(:mnesia_check_act, row)

      assert f.severity == :warning
      assert f.title == "Uniqueness check-then-insert race on a Mnesia table"
      assert f.detail =~ "both insert"
      assert [%{label: "the search that found nothing"}] = f.related
    end

    test "a fill is information, and says what it can overwrite" do
      row = ["M", "M:get/1", ":totals", "0", "M:get/1#6", "M:save/2#9", "dirty_write", "fill"]
      f = Races.finding(:mnesia_check_act, row)

      assert f.severity == :info
      assert f.title =~ "fills"
      assert f.detail =~ "overwritten"
    end

    test "a decision that does more says so" do
      finding =
        Races.finding(:mnesia_check_act, [
          "M",
          "M:handle/2",
          ":charged",
          "0",
          "M:handle/2#4",
          "M:handle/2#9",
          "dirty_write",
          "decides_more"
        ])

      assert finding.severity == :warning
      assert finding.detail =~ "both charge"
    end

    test "a claim and a guard say what the interleaving costs" do
      base = ["M", "M:claim/1", ":claims", "0", "M:claim/1#6", "M:claim/1#9", "dirty_write"]

      assert Races.finding(:mnesia_check_act, base ++ ["claim"]).detail =~ "told they won"
      assert Races.finding(:mnesia_check_act, base ++ ["guarded"]).detail =~ "older can land last"
    end

    test "frames: the same race's other write, a writer outside, another read" do
      for {role, label} <- [
            {"also_writes", "the same race writes here too"},
            {"other_writer", "outside the one process"},
            {"read", "also decided by this dirty read"}
          ] do
        frame = Races.evidence(:mnesia_race_frame, ["M:f/1#9", role, "M:g/1#3", "M:g/1"])
        assert frame.label =~ label
      end
    end
  end
end
