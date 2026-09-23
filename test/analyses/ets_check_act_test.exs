defmodule Argus.Analyses.EtsCheckActTest do
  use ExUnit.Case, async: true

  alias Argus.Analyses.Ets
  alias Argus.Souffle
  alias Argus.Test.Fixtures.CheckThenAct, as: C

  defp skip_without_souffle do
    unless Souffle.available?(), do: flunk("souffle not installed")
  end

  defp races(modules) do
    {:ok, results} = Argus.analyze(modules, :ets)

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

    test "a protected table written only by its owner has one writer" do
      skip_without_souffle()
      assert races([C.ProtectedOwnerOnly]) == []
    end

    test "different keys are not a race" do
      skip_without_souffle()
      assert races([C.DifferentKeys]) == []
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

      f = Ets.finding(:ets_check_act, row)
      assert f.severity == :warning
      assert f.title =~ "Read-then-write"
      assert [%{label: "the read it depends on"}] = f.related
      assert Enum.any?(f.help, &(&1 =~ "insert_new"))
    end
  end
end
