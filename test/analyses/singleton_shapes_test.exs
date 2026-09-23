defmodule Argus.Analyses.SingletonShapesTest do
  use ExUnit.Case, async: true

  alias Argus.Test.Fixtures.{CatchShapes, EtsOwners, InitRecv}
  alias Argus.Test.Rows

  defp skip_without_souffle do
    unless Argus.Souffle.available?(), do: ExUnit.skip("souffle not installed")
  end

  defp erpc_rows(r) do
    r
    |> Rows.where(:failure, "unhandled_failure", kind: "erpc_transport")
    |> Enum.map(&hd/1)
    |> Enum.uniq()
    |> Enum.sort()
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

    assert erpc_rows(r) == ["Argus.Test.Fixtures.CatchShapes.Erpc:partial/4"]
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
          EtsOwners.HelperOwner,
          EtsOwners.InfoOwner,
          EtsOwners.BadargOwner,
          EtsOwners.DynamicOwnerNamedRead
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

  test "a table read inside an Erlang catch is guarded; the same read outside one is not" do
    skip_without_souffle()

    {:ok, r} = Argus.analyze([:ets_catch_reader], :ets)

    assert rows(r, "ets_read_outside_owner", 2) == [":ets_catch_reader:peek/1"]
  end

  test "an :infinity socket receive on init's path is reported; bounded or later is not" do
    skip_without_souffle()

    {:ok, r} =
      Argus.analyze(
        [InitRecv.Blocking, InitRecv.Bounded, InitRecv.Later, InitRecv.Waits],
        :startup
      )

    assert r
           |> Rows.where(:startup, "unbounded_effect_in_init", kind: "recv")
           |> Enum.map(&hd/1)
           |> Enum.uniq()
           |> Enum.sort() == ["Argus.Test.Fixtures.InitRecv.Blocking"]
  end

  test "a receive with no after in init's own process is reported as a wait on a message" do
    skip_without_souffle()

    {:ok, r} =
      Argus.analyze(
        [InitRecv.Waits, InitRecv.AwaitsEach, InitRecv.SpawnsLoop, InitRecv.Blocking],
        :startup
      )

    rows = Rows.where(r, :startup, "unbounded_effect_in_init", kind: "receive")

    # AwaitsEach's closure runs in init's process; SpawnsLoop's loop runs
    # in the process init spawns, and init returns without it.
    assert rows |> Enum.map(&hd/1) |> Enum.uniq() |> Enum.sort() == [
             "Argus.Test.Fixtures.InitRecv.AwaitsEach",
             "Argus.Test.Fixtures.InitRecv.Waits"
           ]

    # Nor are the funs HandsOff gives Task.async_stream and a child spec.
    {:ok, handed} = Argus.analyze([InitRecv.HandsOff], :startup)
    assert Rows.where(handed, :startup, "unbounded_effect_in_init", kind: "receive") == []

    {:ok, findings} =
      Argus.run_analyses([InitRecv.Waits, InitRecv.SpawnsLoop], analyses: [:startup])

    assert ["init/1 waits on a message with no timeout"] ==
             findings.findings |> Enum.map(& &1.title) |> Enum.filter(&(&1 =~ "waits on"))
  end

  test "a connect, a lock or a supervisor call in a task init/1 starts holds nothing" do
    skip_without_souffle()

    {:ok, r} = Argus.analyze([InitRecv.SpawnsWork], :startup)

    assert Rows.where(r, :startup, "unbounded_effect_in_init", kind: "connect") == []
    assert Rows.where(r, :startup, "blocks_on_peer", kind: ["global", "sup"]) == []

    # The lock still waits without bound in the task, which blocking says.
    {:ok, b} = Argus.analyze([InitRecv.SpawnsWork], :blocking)

    assert [["Argus.Test.Fixtures.InitRecv.SpawnsWork:connect/2" | _]] =
             Rows.where(b, :blocking, "unbounded_wait", kind: "global")
  end
end
