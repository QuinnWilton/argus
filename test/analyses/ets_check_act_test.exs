defmodule Argus.Analyses.EtsCheckActTest do
  use ExUnit.Case, async: true

  alias Argus.Analyses.Races
  alias Argus.Souffle
  alias Argus.Test.Batch
  alias Argus.Test.Fixtures.CheckThenAct, as: C
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
    C.WindowCounters,
    C.GvarAccessors,
    C.SerialAccessors,
    C.CounterAccessors,
    C.CounterAccessorChain,
    C.AccessorThroughHelper
  ]

  setup_all do
    %{batch: Batch.solve(:races, [@batched])}
  end

  # A set that shares a module with another test's is about what the
  # modules do together: it is solved on its own (`:alone`), and the
  # batch holds only disjoint sets.
  defp solve(:alone, modules), do: Memo.analyze(modules, :races)
  defp solve(%{batch: batch}, modules), do: Batch.analyze(batch, modules)

  defp skip_without_souffle do
    unless Souffle.available?(), do: flunk("souffle not installed")
  end

  defp races(source, modules) do
    {:ok, results} = solve(source, modules)

    for [_mod, func, name, key, _read, _write] <- results["ets_check_act"],
        do: {func |> String.split(":") |> List.last(), name, key}
  end

  describe "ets_check_act" do
    test "a public table read then inserted on the same key from an API", ctx do
      skip_without_souffle()
      assert [{"put_if_absent/2", ":public_cache", "0"}] = races(ctx, [C.PublicCache])
    end

    test "a write in the last branch, after two returns, still names its key", ctx do
      skip_without_souffle()
      assert [{"bump/2", ":branch_cache", "0"}] = races(ctx, [C.LaterBranchKey])
    end

    test "insert_new is the atomic form", ctx do
      skip_without_souffle()
      assert races(ctx, [C.InsertNewCache]) == []
    end

    test "a Broadway processor's read-then-write races the other processors", ctx do
      skip_without_souffle()
      # One row per write: the absent key's insert and the count's.
      assert Enum.uniq(races(ctx, [C.BroadwayCount])) == [
               {"handle_message/3", ":broadway_counts", ":seen"}
             ]
    end

    test "a protected table written only by its owner has one writer", ctx do
      skip_without_souffle()
      assert races(ctx, [C.ProtectedOwnerOnly]) == []
    end

    test "a cache serialized in its owner, whose clear/0 no caller in the program calls" do
      skip_without_souffle()
      assert races(:alone, [C.SerializedSessionCache, C.SessionAccounts]) == []
    end

    test "the same cache with no client in view is API, clear/0 included", ctx do
      skip_without_souffle()

      assert [{"handle_call/3", ":serialized_sessions", _}] =
               Enum.uniq(races(ctx, [C.SerializedSessionCache]))
    end

    test "a function outside callers can call reaches the cache's clear/0" do
      skip_without_souffle()

      assert [{"handle_call/3", ":serialized_sessions", _}] =
               Enum.uniq(
                 races(:alone, [C.SerializedSessionCache, C.SessionAccounts, C.SessionAdmin])
               )
    end

    test "another process that inserts into the serialized cache's table races it" do
      skip_without_souffle()

      assert [{"handle_call/3", ":serialized_sessions", _}] =
               Enum.uniq(
                 races(:alone, [C.SerializedSessionCache, C.SessionAccounts, C.SessionImporter])
               )
    end

    test "another process that deletes from it races it too: the write puts a revoked row back" do
      skip_without_souffle()

      assert [{"handle_call/3", ":serialized_sessions", _}] =
               Enum.uniq(
                 races(:alone, [C.SerializedSessionCache, C.SessionAccounts, C.SessionReaper])
               )
    end

    test "another process that only deletes loses nothing to an update_element" do
      skip_without_souffle()
      assert races(:alone, [C.SerializedTouch, C.TouchClient, C.TouchReaper]) == []
    end

    test "another process that writes the row whole still races it" do
      skip_without_souffle()

      assert [{"handle_call/3", ":touched_sessions", _}] =
               Enum.uniq(races(:alone, [C.SerializedTouch, C.TouchClient, C.TouchImporter]))
    end

    test "a row seeded in another process's init/1, before the serialized counter runs" do
      skip_without_souffle()
      assert races(:alone, [C.SeedingOwner, C.SerializedCounter]) == []
    end

    test "another process that writes only a literal row of its own beside the counts" do
      skip_without_souffle()
      assert races(:alone, [C.SeedingOwner, C.SerializedCounter, C.VersionStamper]) == []
    end

    test "another process that writes counts by key while the counter runs races it" do
      skip_without_souffle()

      assert [{"handle_call/3", ":serialized_counts", _}] =
               Enum.uniq(races(:alone, [C.SeedingOwner, C.SerializedCounter, C.CountImporter]))
    end

    test "a table of records keyed past the tag (keypos: 2)", ctx do
      skip_without_souffle()
      assert [{"deposit/2", ":accts", "0"}] = Enum.uniq(races(ctx, [C.RecordTable]))
    end

    test "a match on the key is a read that decides; a match with no key names none", ctx do
      skip_without_souffle()
      assert [{"bump/1", ":matched_counts", "0"}] = Enum.uniq(races(ctx, [C.MatchThenWrite]))
    end

    test "different keys are not a race", ctx do
      skip_without_souffle()
      assert races(ctx, [C.DifferentKeys]) == []
    end
  end

  describe "races both racers win" do
    test "a cache refill made by a call, and an invalidating delete, are not reported", ctx do
      skip_without_souffle()
      assert races(ctx, [C.CacheRefill]) == []
    end

    test "a refill that mints the value it hands out is reported: each racer returns its own",
         ctx do
      skip_without_souffle()
      assert [{"token/1", ":tokens", "0"}] = races(ctx, [C.TokenMint])
      assert [{"id/1", ":ids", "0"}] = races(ctx, [C.IdMint])
    end

    test "the refill is reported on a table the program writes back from a read", ctx do
      skip_without_souffle()
      found = races(ctx, [C.RefillWrittenBack])
      assert {"get/1", ":counted_cache", "0"} in found
      assert {"bump/1", ":counted_cache", "0"} in found
    end

    test "a count kept in a literal row of its own does not write the filled rows back", ctx do
      skip_without_souffle()
      assert races(ctx, [C.CacheWithHits]) == []
    end

    test "a trip whose decision stays inside is not reported", ctx do
      skip_without_souffle()
      assert races(ctx, [C.Trip]) == []
    end

    test "a claim whose decision a caller acts on is reported", ctx do
      skip_without_souffle()
      assert [{"claim/1", ":claims", "0"}] = races(ctx, [C.Claim])
    end

    test "a guard on what the row holds is reported, whatever the racers return", ctx do
      skip_without_souffle()
      assert [{"put/2", ":serials_ok", "0"}] = races(ctx, [C.SerialsOk])
    end

    test "a marker whose decision also sends is reported: both racers send", ctx do
      skip_without_souffle()
      assert [{"handle/2", ":notified", "0"}] = races(ctx, [C.NotifyOnce])
    end

    test "a delete decided by the row's owner is reported: it can take the next owner's row",
         ctx do
      skip_without_souffle()
      assert [{"release/2", ":locks", "0"}] = races(ctx, [C.LockRelease])
    end

    test "a trip checked against the clock, whose helper tells the other nodes, is not", ctx do
      skip_without_souffle()
      assert races(ctx, [C.BreakerTrip]) == []
    end

    test "an expired row deleted from a table of refills is not: losing a copy is a miss", ctx do
      skip_without_souffle()
      assert races(ctx, [C.ExpiringCache]) == []
    end

    test "a delete_object of the owner's own row is not", ctx do
      skip_without_souffle()
      assert races(ctx, [C.LockReleaseObject]) == []
    end

    test "a first insert over a key update_counter counts into is reported", ctx do
      skip_without_souffle()
      assert [{"hit/1", ":hits", "0"}] = races(ctx, [C.CounterClobber])
    end

    test "a row holding a counter array is counted in, not filled", ctx do
      skip_without_souffle()
      assert [{"hit/2", ":window_counters", _}] = races(ctx, [C.WindowCounters])
    end
  end

  describe "rows only their holder writes" do
    test "a row made at a monitor of its caller, updated in place by that caller", ctx do
      skip_without_souffle()
      assert races(ctx, [C.HeldParameters]) == []
    end

    test "a row made at a fresh reference the opener returns", ctx do
      skip_without_souffle()
      assert races(ctx, [C.HeldSessions]) == []
    end

    test "a table that also makes rows at keys its callers name is reported", ctx do
      skip_without_souffle()

      assert [{"put/3", "Argus.Test.Fixtures.CheckThenAct.HeldParametersNamed", "0"}] =
               races(ctx, [C.HeldParametersNamed])
    end

    test "a write back with insert is reported: it can put a removed row back", ctx do
      skip_without_souffle()

      assert [{"put/3", "Argus.Test.Fixtures.CheckThenAct.HeldParametersInsert", "0"}] =
               races(ctx, [C.HeldParametersInsert])
    end
  end

  describe "a table the program's users hand in" do
    test "is named by the parameter it arrives in: hammer#129's first insert", ctx do
      skip_without_souffle()
      assert [{"hit/3", "param 0", "1"}] = races(ctx, [C.HandedCounters])
    end

    test "insert_new, hammer#130's fix, is quiet", ctx do
      skip_without_souffle()
      assert races(ctx, [C.HandedCountersFixed]) == []
    end

    test "one the program fills in itself is not the users'", ctx do
      skip_without_souffle()
      assert races(ctx, [C.FetchedTable]) == []
    end
  end

  describe "ets_check_act through accessors" do
    test "a shared key through one-line accessors meets at the calls, in the caller", ctx do
      skip_without_souffle()

      {:ok, results} = Batch.analyze(ctx.batch, [C.GvarAccessors])

      assert [[_mod, func, ":gvar", "0", read, write]] =
               for([_, _, _, "0" | _] = row <- results["ets_check_act"], do: row)

      assert short(func) == "add/2"
      # The read is the call to val/1, the write the call to set/2, both in
      # add/2: not the lookup and the insert inside the accessors.
      assert short(read) == "add/2"
      assert short(write) == "add/2"
    end

    test "a literal an accessor is handed down another chain is no shared key", ctx do
      skip_without_souffle()

      {:ok, results} = Batch.analyze(ctx.batch, [C.GvarAccessors])
      funcs = for [_, func | _] <- results["ets_check_act"], do: short(func)

      refute "maybe_work/0" in funcs
      refute "running?/0" in funcs
    end

    test "a literal the meeting function hands the accessor itself is its own pair", ctx do
      skip_without_souffle()

      {:ok, results} = Batch.analyze(ctx.batch, [C.GvarAccessors])

      # level/0 reads `:level` and hands set/2 the same literal: the pair
      # is level/0's, reported at its set/2 call as the inline pair would
      # be. add/2 writes back to whichever row its callers name.
      assert [[_, func, ":gvar", ":level", read, write]] =
               for([_, _, _, ":level" | _] = row <- results["ets_check_act"], do: row)

      assert short(func) == "level/0"
      assert short(read) == "level/0"
      assert short(write) == "level/0"

      # The counter's getter and setter, both handed `:count` in incr/0.
      assert [{"incr/0", ":counter_accessors", ":count"}] =
               races(ctx, [C.CounterAccessors])
    end

    test "an accessor the meeting function reaches through another call is its own site", ctx do
      skip_without_souffle()

      {:ok, results} = Batch.analyze(ctx.batch, [C.CounterAccessorChain])

      # incr/0 calls set_count/1 but reaches count/0 through next/0: the
      # write is the call, the read the lookup inside count/0.
      assert [[_, func, ":counter_chain", ":count", read, write]] = results["ets_check_act"]
      assert short(func) == "incr/0"
      assert short(read) == "count/0"
      assert short(write) == "incr/0"

      {:ok, results} = Batch.analyze(ctx.batch, [C.AccessorThroughHelper])

      assert [[_, func, ":accessor_helper", "0", read, write]] = results["ets_check_act"]
      assert short(func) == "incr/1"
      assert short(read) == "incr/1"
      assert short(write) == "put/2"
    end

    test "accessors whose bodies name the row meet where both are called", ctx do
      skip_without_souffle()

      assert [{"sync/1", ":decisions", ":serial"}] = races(ctx, [C.SerialAccessors])
    end
  end

  describe "ets_check_act across functions" do
    test "a read helper's result handed to a multi-clause write helper meets in the caller",
         ctx do
      skip_without_souffle()

      {:ok, results} = Batch.analyze(ctx.batch, [C.HelperCache])

      sites =
        for [_mod, func, ":helper_cache", "0", read, write] <- results["ets_check_act"],
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
      skip_without_souffle()

      {:ok, results} = Batch.analyze(ctx.batch, [C.CachedTwice])
      funcs = for [_mod, func | _] <- results["ets_check_act"], uniq: true, do: short(func)

      assert funcs == ["cached/1"]
    end

    test "an unnamed public table handed to a helper by its reference", ctx do
      skip_without_souffle()
      assert [{"count/2", ":unnamed_counts", "1"} | _] = races(ctx, [C.UnnamedTable])
    end
  end

  describe "finding" do
    test "anchors the write, relates the read, and names the atomic forms" do
      row = [
        "M",
        "M:put_if_absent/2",
        ":cache",
        "0",
        "M:put_if_absent/2#4",
        "M:put_if_absent/2#9"
      ]

      f = Races.finding(:ets_check_act, row)
      assert f.severity == :warning
      assert f.title =~ "Read-then-write"
      assert [%{label: "the read it depends on"}] = f.related
      assert Enum.any?(f.help, &(&1 =~ "insert_new"))
      refute f.detail =~ " in M."
    end

    test "names a table the callers hand in by its argument, and says why it is shared" do
      row = ["M", "M:hit/3", "param 0", "1", "M:hit/3#4", "M:hit/3#9"]
      f = Races.finding(:ets_check_act, row)

      assert f.detail =~ "reads a key of the table in its first argument"
      assert f.detail =~ "only a public table allows"
      refute f.detail =~ "param 0"
      assert Enum.any?(f.help, &(&1 =~ "route writes to the table in its first argument"))
    end

    test "names the helpers when the read and the write sit outside the meeting function" do
      row = ["M", "M:bump/1", ":cache", "0", "M:fetch/1#6", "M:store/2#15"]
      f = Races.finding(:ets_check_act, row)

      assert f.detail =~ "in M.fetch/1"
      assert f.detail =~ "in M.store/2"
      assert f.mfa == {M, :store, 2}
    end
  end

  defp short(id), do: id |> String.split("#") |> hd() |> String.split(":") |> List.last()
end
