defmodule Argus.Analyses.EtsMissingRowTest do
  use ExUnit.Case, async: true

  alias Argus.Analyses.Races
  alias Argus.Souffle
  alias Argus.Test.Batch
  alias Argus.Test.Fixtures.MissingRow, as: Fixture

  # Every test reads its fixtures' rows from one solve of them all
  # (`Argus.Test.Batch`; ARGUS_VERIFY_BATCH=1 checks each slice against
  # a solve of its own).
  @batched [
    Fixture.Debounce,
    Fixture.Debounce.Config,
    Fixture.InlineTupleKey,
    Fixture.NameFromConfig,
    Fixture.WithDefault,
    Fixture.Rescued,
    Fixture.OneOwner,
    Fixture.UnrelatedRescue,
    Fixture.HelperRescue,
    Fixture.CallerRescues,
    Fixture.OneCallerRescues,
    Fixture.WrongRescue,
    Fixture.ReraisingRescue,
    Fixture.ClosureCallerRescues,
    Fixture.ClosureCallerUnguarded,
    Fixture.OwnRow,
    Fixture.OwnRowReaped,
    Fixture.SentinelRow,
    Fixture.HelperAct,
    Fixture.HelperCheck,
    Fixture.CrossModuleAct,
    Fixture.Counter,
    Fixture.HandedDebounce,
    Fixture.HandedBesideNamed,
    Fixture.OwnPrivateTable
  ]

  setup_all do
    %{batch: Batch.solve(:races, [@batched])}
  end

  defp skip_without_souffle do
    unless Souffle.available?(), do: flunk("souffle not installed")
  end

  defp missing(%{batch: batch}, modules) do
    {:ok, results} = Batch.analyze(batch, modules)

    for [_mod, func, kind, table, check, act, remover] <- results["ets_missing_row"],
        uniq: true,
        do: {short(func), kind, table, short(check), short(act), short(remover)}
  end

  describe "ets_missing_row on a table the callers hand in" do
    test "a removal below the same way in is on the same table", ctx do
      skip_without_souffle()

      assert [
               {"log/3", "handed_in", "param 0 of " <> way_in, "log/3", "log/3", "drop/2"}
             ] = missing(ctx, [Fixture.HandedDebounce])

      assert way_in =~ "HandedDebounce:log/3"
    end

    test "a named table's removal is not a removal of a handed-in table", ctx do
      skip_without_souffle()
      assert missing(ctx, [Fixture.HandedBesideNamed]) == []
    end

    test "a parameter the program fills with its own private table is that table", ctx do
      skip_without_souffle()
      assert missing(ctx, [Fixture.OwnPrivateTable]) == []
    end
  end

  describe "ets_missing_row" do
    test "a count after a lookup, while a timer's flush takes the row (sequin's shape)", ctx do
      skip_without_souffle()

      assert [{"log/1", "named", ":debounce_buckets", "log/1", "log/1", "flush/2"}] =
               missing(ctx, [Fixture.Debounce, Fixture.Debounce.Config])
    end

    test "a composite key spelled out at the check and again at the act is one key", ctx do
      skip_without_souffle()

      assert [{"log/2", "named", ":inline_tuple_buckets", "log/2", "log/2", "flush/1"}] =
               missing(ctx, [Fixture.InlineTupleKey])
    end

    test "a named table made under a name that arrives at runtime is shared", ctx do
      skip_without_souffle()

      assert [{"log/2", "named", ":config_buckets", "log/2", "log/2", "flush/1"}] =
               missing(ctx, [Fixture.NameFromConfig])
    end

    test "counting with a default object stays quiet", ctx do
      skip_without_souffle()
      assert missing(ctx, [Fixture.WithDefault]) == []
    end

    test "a rescued miss stays quiet", ctx do
      skip_without_souffle()
      assert missing(ctx, [Fixture.Rescued]) == []
    end

    test "one process counting and flushing in its own callbacks stays quiet", ctx do
      skip_without_souffle()
      assert missing(ctx, [Fixture.OneOwner]) == []
    end
  end

  describe "ets_missing_row: where the miss is rescued" do
    test "a rescue around unrelated code after the act does not take its miss", ctx do
      skip_without_souffle()

      assert [{"log/2", "named", ":unrelated_rescue_buckets", "log/2", "log/2", "flush/1"}] =
               missing(ctx, [Fixture.UnrelatedRescue])
    end

    test "a helper that rescues its own act stays quiet", ctx do
      skip_without_souffle()
      assert missing(ctx, [Fixture.HelperRescue]) == []
    end

    test "a private function whose one caller rescues around the call stays quiet", ctx do
      skip_without_souffle()
      assert missing(ctx, [Fixture.CallerRescues]) == []
    end

    test "one caller that does not rescue keeps it reported", ctx do
      skip_without_souffle()

      assert [{"do_log/1", "named", ":one_caller_rescue_buckets", _, _, "flush/1"}] =
               missing(ctx, [Fixture.OneCallerRescues])
    end

    test "a rescue of another exception around the act does not take its miss", ctx do
      skip_without_souffle()

      assert [{"log/1", "named", ":wrong_rescue_buckets", "log/1", "log/1", "flush/1"}] =
               missing(ctx, [Fixture.WrongRescue])
    end

    test "a rescue that raises the miss again does not take it", ctx do
      skip_without_souffle()

      assert [{"log/1", "named", ":reraising_rescue_buckets", "log/1", "log/1", "flush/1"}] =
               missing(ctx, [Fixture.ReraisingRescue])
    end

    test "a closure handed to a call inside a rescue of the miss stays quiet", ctx do
      skip_without_souffle()
      assert missing(ctx, [Fixture.ClosureCallerRescues]) == []
    end

    test "the same closure handed to a call outside the rescue is reported", ctx do
      skip_without_souffle()

      assert [{_, "named", ":closure_unguarded_buckets", _, _, "flush/1"}] =
               missing(ctx, [Fixture.ClosureCallerUnguarded])
    end
  end

  describe "ets_missing_row: which rows a remover can take" do
    test "a process's own row, removed only by the process that owns it, stays quiet", ctx do
      skip_without_souffle()
      assert missing(ctx, [Fixture.OwnRow]) == []
    end

    test "a remover of whichever process's row it is handed can take it", ctx do
      skip_without_souffle()

      assert [{"hit/0", "named", ":reaped_row_counts", "hit/0", "hit/0", "reap/1"}] =
               missing(ctx, [Fixture.OwnRowReaped])
    end

    test "a literal row's remover takes only that row", ctx do
      skip_without_souffle()

      # total/0's pair is raced by reset_total/0 alone; hit/1's keyed rows by neither.
      assert [{"total/0", "named", ":sentinel_counts", "total/0", "total/0", "reset_total/0"}] =
               missing(ctx, [Fixture.SentinelRow])
    end
  end

  describe "ets_missing_row across functions" do
    test "the act in a helper the found-row branch calls", ctx do
      skip_without_souffle()

      assert [{"log/1", "named", ":helper_act_buckets", "log/1", "bump/1", "flush/1"}] =
               missing(ctx, [Fixture.HelperAct])
    end

    test "the check in a helper that returns it", ctx do
      skip_without_souffle()

      assert [{"log/1", "named", ":helper_check_buckets", "exists?/1", "log/1", "flush/1"}] =
               missing(ctx, [Fixture.HelperCheck])
    end

    test "the act in another module", ctx do
      skip_without_souffle()

      assert [{"log/1", "named", ":cross_module_buckets", "log/1", "bump/1", "flush/1"}] =
               missing(ctx, [Fixture.CrossModuleAct, Fixture.Counter])
    end
  end

  describe "finding" do
    test "anchors the act and relates the check and the remover" do
      row = [
        "M",
        "M:log/1",
        "named",
        ":buckets",
        "M:log/1#49",
        "M:log/1#73",
        "M:flush/2#7"
      ]

      f = Races.finding(:ets_missing_row, row)
      assert f.severity == :warning
      assert f.mfa == {M, :log, 1}
      assert f.detail =~ ":buckets"
      assert f.detail =~ "M.flush/2"

      assert [%{label: "the read that decided the row was there"}, %{label: remover}] = f.related
      assert remover =~ "remove"
      assert Enum.any?(f.help, &(&1 =~ "update_counter/4"))
    end

    test "names a handed-in table by the way in and the argument it arrives in" do
      row = [
        "M",
        "M:log/3",
        "handed_in",
        "param 0 of M:log/3",
        "M:log/3#4",
        "M:log/3#20",
        "M:drop/2#3"
      ]

      f = Races.finding(:ets_missing_row, row)
      assert f.detail =~ "the table callers pass M:log/3 as its first argument"
      refute f.detail =~ "param 0"
    end
  end

  defp short(id), do: id |> String.split("#") |> hd() |> String.split(":") |> List.last()
end
