defmodule Argus.Analyses.EtsCheckActTest do
  use ExUnit.Case, async: true
  @moduletag :flowlog

  alias Argus.Analyses.Races
  alias Argus.Test.Batch
  alias Argus.Test.Fixtures.CheckThenAct, as: C
  alias Argus.Test.Fixtures.Dictionary, as: D
  alias Argus.Test.Fixtures.RacesExposureRows, as: Rows
  alias Argus.Test.Memo

  # Every test reads its fixtures' rows from one solve of them all
  # (`Argus.Test.Batch`; ARGUS_VERIFY_BATCH=1 checks each slice against
  # a solve of its own).
  @batched [
    C.HelperCache,
    C.CachedTwice,
    C.PublicCache,
    C.LaterBranchKey,
    C.InsertNewCache,
    C.BroadwayCount,
    C.ProtectedOwnerOnly,
    C.SerializedSessionCache,
    C.RecordTable,
    C.MatchThenWrite,
    C.DifferentKeys,
    C.CacheRefill,
    C.TokenMint,
    C.IdMint,
    C.RefillWrittenBack,
    C.CacheWithHits,
    C.Trip,
    C.Claim,
    C.SerialsOk,
    C.NotifyOnce,
    C.LockRelease,
    C.BreakerTrip,
    C.ExpiringCache,
    C.CaptchaCheck,
    C.CaptchaCheckInline,
    C.LockReleaseObject,
    C.CounterClobber,
    C.UnnamedTable,
    C.HeldParameters,
    C.HeldParametersNamed,
    C.HeldParametersInsert,
    C.HeldSessions,
    C.HandedCounters,
    C.HandedCountersFixed,
    C.FetchedTable,
    C.TwoTablesOneName,
    C.NamedThroughHelper,
    C.ProtectedThroughHelper,
    C.EnsuredCache,
    C.EnsuredTwoCaches,
    C.WindowCounters,
    C.GvarAccessors,
    C.GvarUsers,
    C.SerialAccessors,
    C.CounterAccessors,
    C.CounterAccessorChain,
    C.AccessorThroughHelper,
    D.TmpOptions,
    D.CallerTable,
    D.SharedCallerTable,
    Rows.Sibling,
    Rows.SameRow
  ]

  setup_all do
    %{batch: Batch.solve(:races, [@batched])}
  end

  # A set that shares a module with another test's is about what the
  # modules do together: it is solved on its own (`:alone`), and the
  # batch holds only disjoint sets.
  defp solve(:alone, modules), do: Memo.analyze(modules, :races)
  defp solve(%{batch: batch}, modules), do: Batch.analyze(batch, modules)

  # {function, kind} of each ETS check-then-act.
  defp kinds(source, modules) do
    {:ok, results} = solve(source, modules)

    for [_mod, func, _name, _key, _read, _write, kind] <- results["ets_check_act"],
        do: {func |> String.split(":") |> List.last(), kind}
  end

  defp races(source, modules) do
    {:ok, results} = solve(source, modules)

    for [_mod, func, name, key, _read, _write, _kind] <- results["ets_check_act"],
        do: {func |> String.split(":") |> List.last(), name, key}
  end

  describe "ets_check_act" do
    test "a public table read then inserted on the same key from an API", ctx do
      assert [{"put_if_absent/2", ":public_cache", "0"}] = races(ctx, [C.PublicCache])
    end

    test "a write in the last branch, after two returns, still names its key", ctx do
      assert [{"bump/2", ":branch_cache", "0"}] = races(ctx, [C.LaterBranchKey])
    end

    test "insert_new is the atomic form", ctx do
      assert races(ctx, [C.InsertNewCache]) == []
    end

    test "a Broadway processor's read-then-write races the other processors", ctx do
      # One row per write: the absent key's insert and the count's.
      assert Enum.uniq(races(ctx, [C.BroadwayCount])) == [
               {"handle_message/3", ":broadway_counts", ":seen"}
             ]
    end

    test "a protected table written only by its owner has one writer", ctx do
      assert races(ctx, [C.ProtectedOwnerOnly]) == []
    end

    test "a cache serialized in its owner, whose clear/0 no caller in the program calls" do
      assert races(:alone, [C.SerializedSessionCache, C.SessionAccounts]) == []
    end

    test "the same cache with no client in view is API, clear/0 included", ctx do
      assert [{"handle_call/3", ":serialized_sessions", _}] =
               Enum.uniq(races(ctx, [C.SerializedSessionCache]))
    end

    test "a function outside callers can call reaches the cache's clear/0" do
      assert [{"handle_call/3", ":serialized_sessions", _}] =
               Enum.uniq(
                 races(:alone, [C.SerializedSessionCache, C.SessionAccounts, C.SessionAdmin])
               )
    end

    test "another process that inserts into the serialized cache's table races it" do
      assert [{"handle_call/3", ":serialized_sessions", _}] =
               Enum.uniq(
                 races(:alone, [C.SerializedSessionCache, C.SessionAccounts, C.SessionImporter])
               )
    end

    test "another process that deletes from it races it too: the write puts a revoked row back" do
      assert [{"handle_call/3", ":serialized_sessions", _}] =
               Enum.uniq(
                 races(:alone, [C.SerializedSessionCache, C.SessionAccounts, C.SessionReaper])
               )
    end

    test "another process that only deletes loses nothing to an update_element" do
      assert races(:alone, [C.SerializedTouch, C.TouchClient, C.TouchReaper]) == []
    end

    test "another process that writes the row whole still races it" do
      assert [{"handle_call/3", ":touched_sessions", _}] =
               Enum.uniq(races(:alone, [C.SerializedTouch, C.TouchClient, C.TouchImporter]))
    end

    test "a row seeded in another process's init/1, before the serialized counter runs" do
      assert races(:alone, [C.SeedingOwner, C.SerializedCounter]) == []
    end

    test "another process that writes only a literal row of its own beside the counts" do
      assert races(:alone, [C.SeedingOwner, C.SerializedCounter, C.VersionStamper]) == []
    end

    test "another process that writes counts by key while the counter runs races it" do
      assert [{"handle_call/3", ":serialized_counts", _}] =
               Enum.uniq(races(:alone, [C.SeedingOwner, C.SerializedCounter, C.CountImporter]))
    end

    test "a table of records keyed past the tag (keypos: 2)", ctx do
      assert [{"deposit/2", ":accts", "0"}] = Enum.uniq(races(ctx, [C.RecordTable]))
    end

    test "a match on the key is a read that decides; a match with no key names none", ctx do
      assert [{"bump/1", ":matched_counts", "0"}] = Enum.uniq(races(ctx, [C.MatchThenWrite]))
    end

    test "different keys are not a race", ctx do
      assert races(ctx, [C.DifferentKeys]) == []
    end

    test "tuple keys of another arity or literal are other rows", ctx do
      # phoenix_replay's buffer: `{id, :meta}` beside `{id, :seq}`,
      # `{id, seq}` and `{:collected, id, name}`.
      assert races(ctx, [Rows.Sibling]) == []
    end

    test "a tuple key's own row deleted elsewhere is still a race, and only it", ctx do
      assert [{"handle_cast/2", ":races_exposure_same_row", key}] =
               races(ctx, [Rows.SameRow])

      assert key =~ "literal :meta"

      {:ok, results} = solve(ctx, [Rows.SameRow])

      rivals =
        for [_w, "rival", _site, func] <- results["ets_race_frame"],
            do: func |> String.split(":") |> List.last()

      assert rivals == ["drop/1"]
    end
  end

  describe "races both racers win" do
    test "a refill that is a function of the key, and an invalidating delete, are not reported",
         ctx do
      # get/1's copy is the same whenever it is made; setting/1's copy of
      # a Mnesia record, read before the record changes, can land after
      # invalidate/1 and stay: a stale fill, its rival the invalidation.
      assert kinds(ctx, [C.CacheRefill]) == [{"setting/1", "stale_fill"}]
    end

    test "a refill that mints the value it hands out is reported: each racer returns its own",
         ctx do
      assert [{"token/1", ":tokens", "0"}] = races(ctx, [C.TokenMint])
      assert [{"id/1", ":ids", "0"}] = races(ctx, [C.IdMint])
    end

    test "the refill is reported on a table the program writes back from a read", ctx do
      found = races(ctx, [C.RefillWrittenBack])
      assert {"get/1", ":counted_cache", "0"} in found
      assert {"bump/1", ":counted_cache", "0"} in found
    end

    test "a count kept in a literal row of its own does not write the filled rows back", ctx do
      assert races(ctx, [C.CacheWithHits]) == []
    end

    test "a trip whose decision stays inside is not reported", ctx do
      assert races(ctx, [C.Trip]) == []
    end

    test "a claim whose decision a caller acts on is reported", ctx do
      assert [{"claim/1", ":claims", "0"}] = races(ctx, [C.Claim])
    end

    test "a guard on what the row holds is reported, whatever the racers return", ctx do
      assert [{"put/2", ":serials_ok", "0"}] = races(ctx, [C.SerialsOk])
    end

    test "a marker whose decision also sends is reported: both racers send", ctx do
      assert [{"handle/2", ":notified", "0"}] = races(ctx, [C.NotifyOnce])
    end

    test "a delete decided by the row's owner is reported: it can take the next owner's row",
         ctx do
      assert [{"release/2", ":locks", "0"}] = races(ctx, [C.LockRelease])
    end

    test "a trip checked against the clock, whose helper tells the other nodes, is not", ctx do
      assert races(ctx, [C.BreakerTrip]) == []
    end

    test "an expired row deleted from a table of refills is not: losing a copy is a miss", ctx do
      assert races(ctx, [C.ExpiringCache]) == []

      # A delete whose decision also tells another process — itself, or
      # in a helper it decides the call of — has both racers tell it.
      assert [{"check/1", ":captchas", _}] = races(ctx, [C.CaptchaCheck])
      assert [{"check/1", ":inline_captchas", _}] = races(ctx, [C.CaptchaCheckInline])
    end

    test "a delete_object of the owner's own row is not", ctx do
      assert races(ctx, [C.LockReleaseObject]) == []
    end

    test "a first insert over a key update_counter counts into is reported", ctx do
      assert [{"hit/1", ":hits", "0"}] = races(ctx, [C.CounterClobber])
    end

    test "a row holding a counter array is counted in, not filled", ctx do
      assert [{"hit/2", ":window_counters", _}] = races(ctx, [C.WindowCounters])
    end
  end

  describe "rows only their holder writes" do
    test "a row made at a monitor of its caller, updated in place by that caller", ctx do
      assert races(ctx, [C.HeldParameters]) == []
    end

    test "a row made at a fresh reference the opener returns", ctx do
      assert races(ctx, [C.HeldSessions]) == []
    end

    test "a table that also makes rows at keys its callers name is reported", ctx do
      assert [{"put/3", "Argus.Test.Fixtures.CheckThenAct.HeldParametersNamed", "0"}] =
               races(ctx, [C.HeldParametersNamed])
    end

    test "a write back with insert is reported: it can put a removed row back", ctx do
      assert [{"put/3", "Argus.Test.Fixtures.CheckThenAct.HeldParametersInsert", "0"}] =
               races(ctx, [C.HeldParametersInsert])
    end
  end

  describe "a table the program's users hand in" do
    test "is named by the parameter it arrives in: hammer#129's first insert", ctx do
      assert [{"hit/3", "param 0", "1"}] = races(ctx, [C.HandedCounters])
    end

    test "insert_new, hammer#130's fix, is quiet", ctx do
      assert races(ctx, [C.HandedCountersFixed]) == []
    end

    test "one the program fills in itself is not the users'", ctx do
      assert races(ctx, [C.FetchedTable]) == []
    end
  end

  describe "ets_check_act through accessors" do
    test "a shared key through one-line accessors meets at the calls, in the caller", ctx do
      {:ok, results} = Batch.analyze(ctx.batch, [C.GvarAccessors, C.GvarUsers])

      assert [[_mod, func, ":gvar", "0", read, write, "lost_update"]] =
               for([_, _, _, "0" | _] = row <- results["ets_check_act"], do: row)

      assert short(func) == "add/2"
      # The read is the call to val/1, the write the call to set/2, both in
      # add/2: not the lookup and the insert inside the accessors.
      assert short(read) == "add/2"
      assert short(write) == "add/2"
    end

    test "a constant written on a decision that stays inside is no race", ctx do
      {:ok, results} = Batch.analyze(ctx.batch, [C.GvarAccessors, C.GvarUsers])
      funcs = for [_, func | _] <- results["ets_check_act"], do: short(func)

      # maybe_work/0's set(:status, :stopping) and level/0's default: both
      # racers write the same constant, no caller hears who did, and
      # add/2's rows are the tuples GvarUsers builds, never an atom's.
      refute "maybe_work/0" in funcs
      refute "running?/0" in funcs
      refute "level/0" in funcs
    end

    test "a literal the meeting function hands the accessor itself is its own pair", ctx do
      {:ok, results} = Batch.analyze(ctx.batch, [C.CounterAccessors])

      # incr/0 reads `:count` through get/1 and hands put/2 the same
      # literal and the read plus one: the pair is incr/0's, reported at
      # its calls as the inline pair would be.
      assert [[_, func, ":counter_accessors", ":count", read, write, "lost_update"]] =
               results["ets_check_act"]

      assert short(func) == "incr/0"
      assert short(read) == "incr/0"
      assert short(write) == "incr/0"
    end

    test "an accessor the meeting function reaches through another call is its own site", ctx do
      {:ok, results} = Batch.analyze(ctx.batch, [C.CounterAccessorChain])

      # incr/0 calls set_count/1 but reaches count/0 through next/0: the
      # write is the call, the read the lookup inside count/0.
      assert [[_, func, ":counter_chain", ":count", read, write, _kind]] =
               results["ets_check_act"]

      assert short(func) == "incr/0"
      assert short(read) == "count/0"
      assert short(write) == "incr/0"

      {:ok, results} = Batch.analyze(ctx.batch, [C.AccessorThroughHelper])

      assert [[_, func, ":accessor_helper", "0", read, write, _kind]] = results["ets_check_act"]
      assert short(func) == "incr/1"
      assert short(read) == "incr/1"
      assert short(write) == "put/2"
    end

    test "accessors whose bodies name the row meet where both are called", ctx do
      assert [{"sync/1", ":decisions", ":serial"}] = races(ctx, [C.SerialAccessors])
    end
  end

  describe "ets_check_act across functions" do
    test "a read helper's result handed to a multi-clause write helper meets in the caller",
         ctx do
      {:ok, results} = Batch.analyze(ctx.batch, [C.HelperCache])

      sites =
        for [_mod, func, ":helper_cache", "0", read, write, _kind] <- results["ets_check_act"],
            do: {short(func), short(read), short(write)}

      # fetch/1 is an accessor, one lookup: the read is its call in bump/1.
      # store/2's two clauses insert, one race: the second is a frame.
      assert [{"bump/1", "bump/1", "store/2"}] = sites

      assert [[_write, "also_writes", other, _func]] =
               for(
                 [_, "also_writes", _, _] = frame <- results["ets_race_frame"],
                 do: frame
               )

      assert short(other) == "store/2"
    end

    test "a pair that meets in a helper is not reported again in its caller", ctx do
      {:ok, results} = Batch.analyze(ctx.batch, [C.CachedTwice])
      funcs = for [_mod, func | _] <- results["ets_check_act"], uniq: true, do: short(func)

      assert funcs == ["cached/1"]
    end

    test "an unnamed public table handed to a helper by its reference", ctx do
      assert [{"count/2", ":unnamed_counts", "1"} | _] = races(ctx, [C.UnnamedTable])
    end

    test "two unnamed tables made under one atom are two tables", ctx do
      assert races(ctx, [C.TwoTablesOneName]) == []
    end
  end

  describe "ets_check_act through the process dictionary" do
    test "a table named only while a key is unset is not touched where the key was set", ctx do
      # validate/1 puts its private table under the key first: its read and
      # write touch that table. reload/1 sets nothing, and abort/1 erases
      # the key again before the pair: both touch the public options table,
      # and the pair's one finding is at one of them.
      assert [{func, ":dict_options", ":hosts"}] = Enum.uniq(races(ctx, [D.TmpOptions]))
      assert func in ["abort/1", "reload/1"]
    end

    test "a table its maker keeps in its dictionary is its own", ctx do
      assert races(ctx, [D.CallerTable]) == []
    end

    test "a kept table whose reference is sent on is shared", ctx do
      assert [{"bump/2", ":shared_caller_table", _} | _] = races(ctx, [D.SharedCallerTable])
    end
  end

  describe "ets_check_act on the one table identity" do
    test "a named table a helper makes is public by the helper's options", ctx do
      assert [{"put_if_absent/2", ":helper_named", "0"}] =
               races(ctx, [C.NamedThroughHelper])
    end

    test "the same table made :protected by the helper has one writer", ctx do
      assert races(ctx, [C.ProtectedThroughHelper]) == []
    end

    test "a table a helper returns is the table its :ets.new/2 makes", ctx do
      assert [{"put_if_absent/2", ":ensured_cache", "0"}] = races(ctx, [C.EnsuredCache])
    end

    test "two tables two helpers return are two tables", ctx do
      assert races(ctx, [C.EnsuredTwoCaches]) == []
    end
  end

  describe "finding" do
    @describetag flowlog: false

    test "anchors the write, relates the read, and names the atomic forms" do
      row = [
        "M",
        "M:put_if_absent/2",
        ":cache",
        "0",
        "M:put_if_absent/2#4",
        "M:put_if_absent/2#9",
        "claim"
      ]

      f = Races.finding(:ets_check_act, row)
      assert f.severity == :warning
      assert f.title =~ "Read-then-write"
      assert [%{label: "the read it depends on"}] = f.related
      assert Enum.any?(f.help, &(&1 =~ "insert_new"))
      refute f.detail =~ " in M."
    end

    test "names a table the callers hand in by its argument, and says why it is shared" do
      row = ["M", "M:hit/3", "param 0", "1", "M:hit/3#4", "M:hit/3#9", "lost_update"]
      f = Races.finding(:ets_check_act, row)

      assert f.detail =~ "reads a key of the table in its first argument"
      assert f.detail =~ "only a public table allows"
      refute f.detail =~ "param 0"
      assert Enum.any?(f.help, &(&1 =~ "route writes to the table in its first argument"))
    end

    test "names the helpers when the read and the write sit outside the meeting function" do
      row = ["M", "M:bump/1", ":cache", "0", "M:fetch/1#6", "M:store/2#15", "lost_update"]
      f = Races.finding(:ets_check_act, row)

      assert f.detail =~ "in M.fetch/1"
      assert f.detail =~ "in M.store/2"
      assert f.mfa == {M, :store, 2}
    end
  end

  defp short(id), do: id |> String.split("#") |> hd() |> String.split(":") |> List.last()
end
