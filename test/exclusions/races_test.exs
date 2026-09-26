defmodule Argus.Exclusions.RacesTest do
  @moduledoc """
  Exclusions of the races analysis that no evaluation program exercises
  (census 2026-09-26). Each test pins what one negated atom keeps quiet
  or how it labels a race, beside a twin the analysis does report or the
  row the same fixture does produce, so it cannot pass on a fixture the
  analysis does not read as the test assumes; five pin a real race an
  atom keeps reported. The census is docs/design/exclusions.md; the
  fixtures are in test/fixtures/exclusions/races.ex.
  """
  use ExUnit.Case, async: true

  alias Argus.Souffle
  alias Argus.Test.Batch
  alias Argus.Test.Rows
  alias Excl.Races, as: R

  @start_result_read [R.StartResultRead.Sink, R.StartResultRead.Web, R.StartResultRead.Jobs]
  @locked_quota [R.LockedQuota.Quota, R.LockedQuota.Admin]
  @unlocked_quota [R.UnlockedQuota.Quota, R.UnlockedQuota.Admin]
  @handed_record [R.HandedRecordCounter.Counters, R.HandedRecordCounter.Web]

  # Every test reads its fixtures' rows from one solve of them all
  # (`Argus.Test.Batch`; ARGUS_VERIFY_BATCH=1 checks each slice against a
  # solve of its own).
  @batched [
    @start_result_read,
    [R.HandedTableCharge],
    [R.HandedTableHits],
    [R.SingleSweeper],
    [R.OpenBump],
    [R.TwoWayOneTable],
    [R.TwoWayTwoTables],
    [R.PrivateInterner],
    [R.PublicInterner],
    @locked_quota,
    @unlocked_quota,
    [R.LockedSequence],
    [R.LeakySequence],
    @handed_record,
    [R.SerialCheck],
    [R.EnsureDefault],
    [R.EnsureCreated],
    [R.IndexVisit],
    [R.Prerender]
  ]

  @fixture Path.expand("../fixtures/exclusions/races.ex", __DIR__)

  setup_all do
    %{batch: Batch.solve(:races, @batched)}
  end

  defp results(%{batch: batch}, set) do
    unless Souffle.available?(), do: flunk("souffle not installed")
    {:ok, results} = Batch.analyze(batch, set)
    results
  end

  # {function, table, key} of each ETS check-then-act.
  defp ets_races(ctx, set) do
    for [func, name, key] <-
          Rows.where(results(ctx, set), :races, "ets_check_act",
            drop: [:mod, :read, :write, :kind]
          ),
        do: {short(func), name, key}
  end

  # {function, table, kind} of each Mnesia check-then-act.
  defp record_races(ctx, set) do
    for [func, table, kind] <-
          Rows.where(results(ctx, set), :races, "mnesia_check_act",
            drop: [:mod, :key, :read, :write, :op]
          ),
        do: {short(func), table, kind}
  end

  # The reader function of each publish-order row.
  defp publish_readers(ctx, set) do
    for [reader] <-
          Rows.where(results(ctx, set), :races, "ets_publish_order",
            drop: [
              :mod,
              :func,
              :published_kind,
              :published_in,
              :completed_kind,
              :completed_in,
              :publish,
              :complete
            ]
          ),
        do: short(reader)
  end

  # A function's name and arity, without its module or instruction.
  defp short(id), do: id |> String.split(":") |> List.last() |> String.split("#") |> hd()

  # The fixture's line holding `text`, found by the text so the fixture
  # can move freely.
  defp fixture_line(text) do
    @fixture
    |> File.read!()
    |> String.split("\n")
    |> Enum.find_index(&String.contains?(&1, text))
    |> Kernel.+(1)
  end

  describe "kept: a registry race whose loser acts on the start's result" do
    # races.dl, loser_dropped: !returned_and_used(a).
    test "a start in a helper whose result the meeting function reads", ctx do
      assert [["Excl.Races.StartResultRead.Sink:ensure/1", "whereis", "start"]] =
               Rows.where(results(ctx, @start_result_read), :races, "registry_race",
                 drop: [:mod, :key_source, :key, :check, :act]
               )
    end
  end

  describe "kept: a lost update whose write is in a helper" do
    # races.dl, harmless_race: !carries_read(w), in both of its rules.
    test "a table the caller hands in, written back by a helper with the read plus a cost", ctx do
      assert ets_races(ctx, [R.HandedTableCharge]) == [{"charge/3", "param 0", "1"}]
    end

    # races.dl, harmless_race: !carries_read(w), in its second rule (the
    # decision stays in the function).
    test "a table the caller hands in, written back by a helper with the read plus one", ctx do
      assert ets_races(ctx, [R.HandedTableHits]) == [{"hit/2", "param 0", "1"}]
    end

    # races.dl, harmless_record_race: !record_carries_read(w).
    test "a Mnesia table the caller names, written back by a helper with the read plus one",
         ctx do
      assert record_races(ctx, @handed_record) ==
               [{"bump/2", ":excl_races_views", "lost_update"}]
    end

    # races.dl, harmless_record_race: !guards_record(r, w).
    test "a newer-serial check whose guard is the only condition on the write", ctx do
      assert record_races(ctx, [R.SerialCheck]) ==
               [{"record/2", ":excl_races_serials", "guarded"}]
    end
  end

  describe "a check-then-act with no second writer in view" do
    # races.dl, ets_race: !runs.single_process(func).
    test "a handed table's only writer is the one sweeper process the library spawns", ctx do
      assert ets_races(ctx, [R.SingleSweeper]) == []
      assert ets_races(ctx, [R.OpenBump]) == [{"bump/1", "param 0", ":generation"}]
    end

    # races.dl, racing_record_pair: !serialized_by_lock(f, t).
    test "a Mnesia read-modify-write whose every writer holds the same :global lock", ctx do
      assert record_races(ctx, @locked_quota) == []

      assert record_races(ctx, @unlocked_quota) ==
               [{"-handle_call/3-fun-0-/1", ":excl_races_open_quota", "lost_update"}]
    end

    # races.dl, called_unlocked: !locked_closure(h).
    test "a Mnesia write in a helper only the locked closure calls", ctx do
      assert record_races(ctx, [R.LockedSequence]) == []

      assert record_races(ctx, [R.LeakySequence]) ==
               [{"-next/1-fun-0-/1", ":excl_races_leaky_seq", "lost_update"}]
    end
  end

  describe "a table published before it is complete" do
    # races.dl, key_may_come_from: in a table that holds both rows, a key
    # from outside the program may be the published row's own, which is
    # written first; a reader must take the value from the table. (The
    # retired !may_share_table(w1, w2) left one-table maps out whole.)
    test "a reader of the row a one-table map writes first cannot meet the gap", ctx do
      refute "id_of/1" in publish_readers(ctx, [R.TwoWayOneTable])
      assert publish_readers(ctx, [R.TwoWayTwoTables]) == ["name_of/1"]
    end

    # races.dl, readable_elsewhere: !ets_option(n, "access", "private").
    test "private tables a process keeps for itself in a map", ctx do
      assert publish_readers(ctx, [R.PrivateInterner]) == []
      assert publish_readers(ctx, [R.PublicInterner]) == ["name_of/2"]
    end
  end

  describe "how a Mnesia race is labelled" do
    # races.dl, record_decision_escapes: !callee_returns(g, "constant").
    test "an ensure-default that answers :ok whatever happened is no claim", ctx do
      assert record_races(ctx, [R.EnsureDefault]) == []

      assert record_races(ctx, [R.EnsureCreated]) ==
               [{"ensure/1", ":excl_races_created_prefs", "claim"}]
    end

    # races.dl, record_race_kind: !record_pair_carries_read(r, w).
    test "a search read's found branch writing back plus one is not the duplicate", ctx do
      {:ok, facts} = Argus.Pipeline.extract([R.IndexVisit])
      lines = Argus.Lines.from_facts(facts)

      reported =
        for [write, kind] <-
              Rows.where(results(ctx, [R.IndexVisit]), :races, "mnesia_check_act",
                drop: [:mod, :func, :table, :key, :read, :op]
              ),
            do: {kind, Argus.Lines.resolve(lines, write)}

      # The miss branch's insert under a fresh id, not the found branch's
      # write-back.
      assert reported == [
               {"unique", fixture_line("System.unique_integer([:positive]), email, 1")}
             ]
    end

    # A claim is a verdict the caller acts on (races.dl, record_race_kind
    # "claim"): warm_all/1 counts the :miss answers, and two racers that
    # both miss both answer :miss. (The retired !record_recomputed(r, w)
    # labelled it a fill.)
    test "a warmer that stores a render on a miss and answers :hit or :miss claims", ctx do
      assert record_races(ctx, [R.Prerender]) == [{"warm/1", ":excl_races_pages", "claim"}]
    end
  end
end
