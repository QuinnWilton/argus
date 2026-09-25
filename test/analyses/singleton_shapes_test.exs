defmodule Argus.Analyses.SingletonShapesTest do
  use ExUnit.Case, async: true

  alias Argus.Test.Fixtures.{CatchShapes, EtsOwners, InitRecv}
  alias Argus.Test.Memo
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
      Memo.analyze(
        [CatchShapes.NoprocOnly, CatchShapes.NoprocAndShutdown, CatchShapes.AnyExit],
        :blocking
      )

    assert rows(r, "partial_noproc_catch") ==
             ["Argus.Test.Fixtures.CatchShapes.NoprocOnly:sync_with_parent/1"]
  end

  test "an :erpc rescue with no clause for transport failures is reported" do
    skip_without_souffle()

    {:ok, r} = Memo.analyze([CatchShapes.Erpc], :failure)

    assert erpc_rows(r) == ["Argus.Test.Fixtures.CatchShapes.Erpc:partial/4"]
  end

  test "a table read from outside its owner without heir or rescue is reported" do
    skip_without_souffle()

    {:ok, r} =
      Memo.analyze(
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

    {:ok, r} = Memo.analyze([:ets_catch_reader], :ets)

    assert rows(r, "ets_read_outside_owner", 2) == [":ets_catch_reader:peek/1"]
  end

  test "an :infinity socket receive on init's path is reported; bounded or later is not" do
    skip_without_souffle()

    {:ok, r} =
      Memo.analyze(
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
      Memo.analyze(
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

    # Nor is the fun HandsOff puts in a child spec; but beside another
    # closure it is not known to be the child's, and the wait in
    # HandsOffAndWaits's Enum.each closure is init's.
    {:ok, handed} =
      Memo.analyze([InitRecv.HandsOff, InitRecv.HandsOffAndWaits], :startup)

    assert handed
           |> Rows.where(:startup, "unbounded_effect_in_init", kind: "receive")
           |> Enum.map(&hd/1)
           |> Enum.uniq() == ["Argus.Test.Fixtures.InitRecv.HandsOffAndWaits"]

    {:ok, findings} =
      Memo.run_analyses([InitRecv.Waits, InitRecv.SpawnsLoop], analyses: [:startup])

    assert ["init/1 waits on a message with no timeout"] ==
             findings.findings |> Enum.map(& &1.title) |> Enum.filter(&(&1 =~ "waits on"))
  end

  test "a flush, or a wait after the ack, holds no start; a wait a peer ends is a down" do
    skip_without_souffle()

    fixtures = [
      InitRecv.AcksThenLoops,
      InitRecv.AcksThenWaits,
      InitRecv.AsksWithMonitor,
      InitRecv.AwaitsHandedDown,
      InitRecv.ClosesPort,
      InitRecv.FlushesTimer,
      InitRecv.FlushesOnFalse,
      InitRecv.WaitsBeforeAck,
      InitRecv.LoopsOnParent,
      InitRecv.AsksByHand,
      InitRecv.UnlinkedExit,
      InitRecv.LinkedUntrapped,
      InitRecv.CancelsHanded,
      InitRecv.FlushesUnchecked
    ]

    {:ok, r} = Memo.analyze(fixtures, :startup)

    mods = fn kind ->
      r
      |> Rows.where(:startup, "unbounded_effect_in_init", kind: kind)
      |> Enum.map(&(&1 |> hd() |> String.replace("Argus.Test.Fixtures.InitRecv.", "")))
      |> Enum.uniq()
      |> Enum.sort()
    end

    # A receive before the ack holds the starter; a loop's clause for its
    # parent's exit does not bound its wait for the next message. An
    # :EXIT clause bounds nothing unless the process traps exits and its
    # function links to the one it waits on; a cancel bounds nothing
    # unless the receive runs on its `false` side.
    assert mods.("receive") ==
             ~w(CancelsHanded FlushesUnchecked LinkedUntrapped LoopsOnParent UnlinkedExit
                WaitsBeforeAck)

    # A pinned :DOWN, or a trapped :EXIT of a linked port, ends the wait
    # when the other process does; one that lives and does not answer
    # holds the start.
    assert mods.("down") == ~w(AsksByHand AsksWithMonitor AwaitsHandedDown ClosesPort)

    # With gen_server's own code in the program: the loop enter_loop
    # runs is the server's, entered after the ack.
    {:ok, r} = Memo.analyze([InitRecv.AcksThenLoops, :gen_server], :startup)
    assert Rows.where(r, :startup, "unbounded_effect_in_init", kind: "receive") == []
    assert Rows.where(r, :startup, "unbounded_effect_in_init", kind: "enter_loop") == []
  end

  test "init/1 entering the server loop before any ack holds its start for good" do
    skip_without_souffle()

    {:ok, r} = Memo.analyze([InitRecv.EntersWithoutAck, InitRecv.AcksThenLoops], :startup)

    assert [["Argus.Test.Fixtures.InitRecv.EntersWithoutAck", "enter_loop", api, _site]] =
             Rows.where(r, :startup, "unbounded_effect_in_init", kind: "enter_loop")

    assert api == "Argus.Test.Fixtures.InitRecv.EntersWithoutAck:init/1"
  end

  test "a call a task init/1 starts makes to a later sibling is no deadlock" do
    skip_without_souffle()

    alias InitRecv.TaskCalls

    {:ok, r} =
      Memo.analyze([TaskCalls.Sup, TaskCalls.Early, TaskCalls.Later], :startup)

    assert Rows.where(r, :startup, "blocks_on_peer", phase: "init", kind: "call") == []
  end

  test "a connect, a lock or a supervisor call in a task init/1 starts holds nothing" do
    skip_without_souffle()

    {:ok, r} = Memo.analyze([InitRecv.SpawnsWork], :startup)

    assert Rows.where(r, :startup, "unbounded_effect_in_init", kind: "connect") == []
    assert Rows.where(r, :startup, "blocks_on_peer", kind: ["global", "sup"]) == []

    # The lock still waits without bound in the task, which blocking says.
    {:ok, b} = Memo.analyze([InitRecv.SpawnsWork], :blocking)

    assert [["Argus.Test.Fixtures.InitRecv.SpawnsWork:connect/2" | _]] =
             Rows.where(b, :blocking, "unbounded_wait", kind: "global")
  end
end
