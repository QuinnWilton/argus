defmodule Argus.Analyses.MnesiaCheckActTest do
  use ExUnit.Case, async: true

  alias Argus.Analyses.Ets
  alias Argus.Souffle
  alias Argus.Test.Fixtures.CheckThenAct, as: C

  defp skip_without_souffle do
    unless Souffle.available?(), do: flunk("souffle not installed")
  end

  defp races(modules) do
    {:ok, results} = Argus.analyze(modules, :ets)

    for [_mod, func, table, key, read, write] <- results["mnesia_check_act"],
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

    test "a transaction, the atomic counter, and a different record are quiet" do
      skip_without_souffle()
      assert races([C.MnesiaTransaction, C.MnesiaUpdateCounter, C.MnesiaOtherKey]) == []
    end

    test "a table only its owner's callbacks write has one writer" do
      skip_without_souffle()
      assert races([C.MnesiaOwner]) == []
    end
  end

  describe "finding" do
    test "anchors the dirty write, relates the dirty read, and names the transaction" do
      row = ["M", "M:bump/1", ":counters", "0", "M:get/1#6", "M:bump/1#27"]
      f = Ets.finding(:mnesia_check_act, row)

      assert f.severity == :warning
      assert f.title =~ "Mnesia"
      assert f.detail =~ "dirty read in M.get/1"
      assert [%{label: "the dirty read it depends on"}] = f.related
      assert Enum.any?(f.help, &(&1 =~ "transaction"))
      assert Enum.any?(f.help, &(&1 =~ "dirty_update_counter"))
    end
  end
end
