defmodule Argus.Analyses.SingletonShapesTest do
  use ExUnit.Case, async: false

  alias Argus.Test.Fixtures.{CatchShapes, EtsOwners, InitRecv}

  defp skip_without_souffle do
    unless Argus.Souffle.available?(), do: ExUnit.skip("souffle not installed")
  end

  defp rows(results, relation, column \\ 0),
    do:
      results
      |> Map.get(relation, [])
      |> Enum.map(&Enum.at(&1, column))
      |> Enum.uniq()
      |> Enum.sort()

  test "a peer call catching only :noproc is reported; :shutdown or a bare reason is not" do
    skip_without_souffle()

    {:ok, r} =
      Argus.analyze(
        [CatchShapes.NoprocOnly, CatchShapes.NoprocAndShutdown, CatchShapes.AnyExit],
        :blocking
      )

    assert rows(r, "partial_noproc_catch") ==
             ["Argus.Test.Fixtures.CatchShapes.NoprocOnly:sync_with_parent/1"]
  end

  test "an :erpc rescue with no clause for transport failures is reported" do
    skip_without_souffle()

    {:ok, r} = Argus.analyze([CatchShapes.Erpc], :failure)

    assert rows(r, "erpc_transport_unhandled") == [
             "Argus.Test.Fixtures.CatchShapes.Erpc:partial/4"
           ]
  end

  test "a table read from outside its owner without heir or rescue is reported" do
    skip_without_souffle()

    {:ok, r} =
      Argus.analyze(
        [
          EtsOwners.Owner,
          EtsOwners.GuardedOwner,
          EtsOwners.ClosureGuardedOwner,
          EtsOwners.HeirOwner,
          EtsOwners.InsideOwner,
          EtsOwners.Helper,
          EtsOwners.HelperOwner
        ],
        :ets
      )

    assert rows(r, "ets_read_outside_owner", 1) == [
             "Argus.Test.Fixtures.EtsOwners.HelperOwner",
             "Argus.Test.Fixtures.EtsOwners.Owner"
           ]

    assert rows(r, "ets_read_outside_owner", 2) == [
             "Argus.Test.Fixtures.EtsOwners.HelperOwner:lookup/1",
             "Argus.Test.Fixtures.EtsOwners.Owner:lookup/1"
           ]
  end

  test "an :infinity socket receive on init's path is reported; bounded or later is not" do
    skip_without_souffle()

    {:ok, r} =
      Argus.analyze(
        [InitRecv.Blocking, InitRecv.Bounded, InitRecv.Later, InitRecv.Waits],
        :startup
      )

    assert rows(r, "blocking_recv_in_init") == [
             "Argus.Test.Fixtures.InitRecv.Blocking",
             "Argus.Test.Fixtures.InitRecv.Waits"
           ]
  end
end
