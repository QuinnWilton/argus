defmodule Argus.Analyses.EtsCheckActTest do
  use ExUnit.Case, async: true

  alias Argus.Analyses.Races
  alias Argus.Souffle
  alias Argus.Test.Fixtures.CheckThenAct, as: C

  defp skip_without_souffle do
    unless Souffle.available?(), do: flunk("souffle not installed")
  end

  defp races(modules) do
    {:ok, results} = Argus.analyze(modules, :races)

    for [_mod, func, name, key, _read, _write] <- results["ets_check_act"],
        do: {func |> String.split(":") |> List.last(), name, key}
  end

  describe "ets_check_act" do
    test "a public table read then inserted on the same key from an API" do
      skip_without_souffle()
      assert [{"put_if_absent/2", ":public_cache", "0"}] = races([C.PublicCache])
    end

    test "a write in the last branch, after two returns, still names its key" do
      skip_without_souffle()
      assert [{"bump/2", ":branch_cache", "0"}] = races([C.LaterBranchKey])
    end

    test "insert_new is the atomic form" do
      skip_without_souffle()
      assert races([C.InsertNewCache]) == []
    end

    test "a Broadway processor's read-then-write races the other processors" do
      skip_without_souffle()
      # One row per write: the absent key's insert and the count's.
      assert Enum.uniq(races([C.BroadwayCount])) == [
               {"handle_message/3", ":broadway_counts", ":seen"}
             ]
    end

    test "a protected table written only by its owner has one writer" do
      skip_without_souffle()
      assert races([C.ProtectedOwnerOnly]) == []
    end

    test "different keys are not a race" do
      skip_without_souffle()
      assert races([C.DifferentKeys]) == []
    end
  end

  describe "races both racers win" do
    test "a cache refill made by a call, and an invalidating delete, are not reported" do
      skip_without_souffle()
      assert races([C.CacheRefill]) == []
    end

    test "the refill is reported on a table the program writes back from a read" do
      skip_without_souffle()
      found = races([C.RefillWrittenBack])
      assert {"get/1", ":counted_cache", "0"} in found
      assert {"bump/1", ":counted_cache", "0"} in found
    end

    test "a trip whose decision stays inside is not reported" do
      skip_without_souffle()
      assert races([C.Trip]) == []
    end

    test "a claim whose decision a caller acts on is reported" do
      skip_without_souffle()
      assert [{"claim/1", ":claims", "0"}] = races([C.Claim])
    end

    test "a first insert over a key update_counter counts into is reported" do
      skip_without_souffle()
      assert [{"hit/1", ":hits", "0"}] = races([C.CounterClobber])
    end
  end

  describe "ets_check_act across functions" do
    test "a read helper's result handed to a multi-clause write helper meets in the caller" do
      skip_without_souffle()

      {:ok, results} = Argus.analyze([C.HelperCache], :races)

      sites =
        for [_mod, func, ":helper_cache", "0", read, write] <- results["ets_check_act"],
            do: {short(func), short(read), short(write)}

      assert Enum.uniq(Enum.map(sites, &elem(&1, 0))) == ["bump/1"]
      assert Enum.all?(sites, fn {_, read, write} -> read == "fetch/1" and write == "store/2" end)
      # One row per store/2 clause's insert.
      assert length(sites) == 2
    end

    test "a pair that meets in a helper is not reported again in its caller" do
      skip_without_souffle()

      {:ok, results} = Argus.analyze([C.CachedTwice], :races)
      funcs = for [_mod, func | _] <- results["ets_check_act"], uniq: true, do: short(func)

      assert funcs == ["cached/1"]
    end

    test "an unnamed public table handed to a helper by its reference" do
      skip_without_souffle()
      assert [{"count/2", ":unnamed_counts", "1"} | _] = races([C.UnnamedTable])
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
