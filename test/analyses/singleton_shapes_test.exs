defmodule Argus.Analyses.SingletonShapesTest do
  use ExUnit.Case, async: true
  @moduletag :flowlog

  alias Argus.Test.Fixtures.{CatchShapes, EtsOwners, InitAck, InitRecv}
  alias Argus.Test.Memo
  alias Argus.Test.Rows

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

  # NoprocAndShutdown is phoenix_live_view#4359's child with a clause for
  # `{:shutdown, _}` beside `:noproc`: the parent stops with
  # `{:shutdown, {:redirect, _}}`, and the call exits
  # `{{:shutdown, _}, _}`, which neither clause takes. It was pinned quiet
  # while the catch facts could not tell the two shapes apart.
  test "a peer call catching :noproc, or :noproc and the bare :shutdown, is reported; a bare reason is not" do
    {:ok, r} =
      Memo.analyze(
        [CatchShapes.NoprocOnly, CatchShapes.NoprocAndShutdown, CatchShapes.AnyExit],
        :blocking
      )

    assert rows(r, "partial_noproc_catch") == [
             "Argus.Test.Fixtures.CatchShapes.NoprocAndShutdown:sync_with_parent/1",
             "Argus.Test.Fixtures.CatchShapes.NoprocOnly:sync_with_parent/1"
           ]
  end

  test "a clause that takes every tuple reason covers a peer that stops mid-call" do
    {:ok, r} =
      Memo.analyze([CatchShapes.NoprocAndAnyTuple, CatchShapes.NoprocAndNamedTuple], :blocking)

    # Positive: a second clause for one more tag still leaves :shutdown out.
    assert rows(r, "partial_noproc_catch") ==
             ["Argus.Test.Fixtures.CatchShapes.NoprocAndNamedTuple:sync_with_parent/1"]
  end

  test "an :erpc rescue with no clause for transport failures is reported" do
    {:ok, r} = Memo.analyze([CatchShapes.Erpc], :failure)

    assert erpc_rows(r) == ["Argus.Test.Fixtures.CatchShapes.Erpc:partial/4"]
  end

  test "a table read from outside its owner without heir or rescue is reported" do
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
          EtsOwners.DynamicOwnerNamedRead,
          EtsOwners.UnrelatedRescueOwner,
          EtsOwners.SpawnedReader,
          EtsOwners.HelperUnrelatedRescueOwner,
          EtsOwners.HelperGuardedOwner,
          EtsOwners.CallerRescuedOwner,
          EtsOwners.WrongRescueOwner
        ],
        :ets
      )

    # A rescue guards the read it covers, the call into the helper that
    # reads, or every call to the reader; not one elsewhere in the reader
    # (UnrelatedRescueOwner, HelperUnrelatedRescueOwner) nor one of another
    # exception (WrongRescueOwner). A task the owner starts runs apart
    # from it (SpawnedReader).
    assert rows(r, "ets_read_outside_owner", 1) == [
             "Argus.Test.Fixtures.EtsOwners.HelperOwner",
             "Argus.Test.Fixtures.EtsOwners.HelperUnrelatedRescueOwner",
             "Argus.Test.Fixtures.EtsOwners.Owner",
             "Argus.Test.Fixtures.EtsOwners.SpawnedReader",
             "Argus.Test.Fixtures.EtsOwners.UnrelatedRescueOwner",
             "Argus.Test.Fixtures.EtsOwners.WrongRescueOwner"
           ]

    assert rows(r, "ets_read_outside_owner", 2) == [
             "Argus.Test.Fixtures.EtsOwners.HelperOwner:lookup/1",
             "Argus.Test.Fixtures.EtsOwners.HelperUnrelatedRescueOwner:lookup/1",
             "Argus.Test.Fixtures.EtsOwners.Owner:lookup/1",
             "Argus.Test.Fixtures.EtsOwners.SpawnedReader:-handle_cast/2-fun-0-/1",
             "Argus.Test.Fixtures.EtsOwners.UnrelatedRescueOwner:lookup/1",
             "Argus.Test.Fixtures.EtsOwners.WrongRescueOwner:lookup/1"
           ]
  end

  test "a reader that asks :ets.whereis/1 first is guarded; one that asks elsewhere is not" do
    {:ok, r} =
      Memo.analyze([EtsOwners.WhereisOwner, EtsOwners.WhereisElsewhereOwner], :ets)

    assert rows(r, "ets_read_outside_owner", 2) == [
             "Argus.Test.Fixtures.EtsOwners.WhereisElsewhereOwner:lookup/1"
           ]
  end

  test "a table read inside an Erlang catch is guarded; the same read outside one is not" do
    {:ok, r} = Memo.analyze([:ets_catch_reader], :ets)

    assert rows(r, "ets_read_outside_owner", 2) == [":ets_catch_reader:peek/1"]
  end

  test "an :infinity socket receive on init's path is reported; bounded or later is not" do
    {:ok, r} =
      Memo.analyze(
        [InitRecv.Blocking, InitRecv.Bounded, InitRecv.Later, InitRecv.Waits],
        :startup
      )

    assert r
           |> Rows.where(:startup, "unbounded_effect_in_init",
             kind: "recv",
             drop: [:peer, :permille]
           )
           |> Enum.map(&hd/1)
           |> Enum.uniq()
           |> Enum.sort() == ["Argus.Test.Fixtures.InitRecv.Blocking"]
  end

  test "a receive with no after in init's own process is reported as a wait on a message" do
    {:ok, r} =
      Memo.analyze(
        [InitRecv.Waits, InitRecv.AwaitsEach, InitRecv.SpawnsLoop, InitRecv.Blocking],
        :startup
      )

    rows =
      Rows.where(r, :startup, "unbounded_effect_in_init",
        kind: "receive",
        drop: [:peer, :permille]
      )

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
           |> Rows.where(:startup, "unbounded_effect_in_init",
             kind: "receive",
             drop: [:peer, :permille]
           )
           |> Enum.map(&hd/1)
           |> Enum.uniq() == ["Argus.Test.Fixtures.InitRecv.HandsOffAndWaits"]

    # Logging on the way is a side path; the wait beside it still holds
    # the start.
    {:ok, logs} = Memo.analyze([InitRecv.LogsAndWaits, :logger, :logger_backend], :startup)

    assert logs
           |> Rows.where(:startup, "unbounded_effect_in_init",
             kind: "receive",
             drop: [:peer, :permille]
           )
           |> Enum.map(&hd/1)
           |> Enum.uniq() == ["Argus.Test.Fixtures.InitRecv.LogsAndWaits"]

    {:ok, findings} =
      Memo.run_analyses([InitRecv.Waits, InitRecv.SpawnsLoop], analyses: [:startup])

    assert ["init/1 waits on a message with no timeout"] ==
             findings.findings |> Enum.map(& &1.title) |> Enum.filter(&(&1 =~ "waits on"))
  end

  test "a flush, or a wait after the ack, holds no start; a wait a peer ends is a down" do
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
      InitRecv.FlushesUnchecked,
      InitRecv.TrapsAfterWait,
      InitRecv.TrapsInHelperFirst,
      InitRecv.TrapsThenClears,
      InitRecv.TrapsOnOption
    ]

    {:ok, r} = Memo.analyze(fixtures, :startup)

    mods = fn kind ->
      r
      |> Rows.where(:startup, "unbounded_effect_in_init", kind: kind, drop: [:peer, :permille])
      |> Enum.map(&(&1 |> hd() |> String.replace("Argus.Test.Fixtures.InitRecv.", "")))
      |> Enum.uniq()
      |> Enum.sort()
    end

    # A receive before the ack holds the starter; a loop's clause for its
    # parent's exit does not bound its wait for the next message. An
    # :EXIT clause bounds nothing unless the process is trapping exits
    # when it waits (a trap set after the wait, or cleared before it, is
    # not) and its function links to the one it waits on; a cancel bounds
    # nothing unless the receive runs on its `false` side.
    assert mods.("receive") ==
             ~w(CancelsHanded FlushesUnchecked LinkedUntrapped LoopsOnParent TrapsAfterWait
                TrapsThenClears UnlinkedExit WaitsBeforeAck)

    # A pinned :DOWN, or a trapped :EXIT of a linked process or port (the
    # trap set earlier, by a helper, or on one path), ends the wait when
    # the other process does; one that lives and does not answer holds
    # the start.
    assert mods.("down") ==
             ~w(AsksByHand AsksWithMonitor AwaitsHandedDown ClosesPort TrapsInHelperFirst
                TrapsOnOption)

    # With gen_server's own code in the program: the loop enter_loop
    # runs is the server's, entered after the ack.
    {:ok, r} = Memo.analyze([InitRecv.AcksThenLoops, :gen_server], :startup)

    assert Rows.where(r, :startup, "unbounded_effect_in_init",
             kind: "receive",
             drop: [:peer, :permille]
           ) == []

    assert Rows.where(r, :startup, "unbounded_effect_in_init",
             kind: "enter_loop",
             drop: [:peer, :permille]
           ) == []
  end

  test "init/1 entering the server loop before any ack holds its start for good" do
    {:ok, r} = Memo.analyze([InitRecv.EntersWithoutAck, InitRecv.AcksThenLoops], :startup)

    assert [["Argus.Test.Fixtures.InitRecv.EntersWithoutAck", "enter_loop", api, _site]] =
             Rows.where(r, :startup, "unbounded_effect_in_init",
               kind: "enter_loop",
               drop: [:peer, :permille]
             )

    assert api == "Argus.Test.Fixtures.InitRecv.EntersWithoutAck:init/1"
  end

  test "what init/1 runs after it acknowledges its start is the server's, not the start's" do
    {:ok, r} =
      Memo.analyze(
        [
          InitAck.RpcBefore,
          InitAck.RpcAfter,
          InitAck.LockBefore,
          InitAck.LockAfter,
          InitAck.CallsBefore,
          InitAck.CallsAfter,
          InitAck.Later,
          InitAck.Sup
        ],
        :startup
      )

    heads = fn filters ->
      r
      |> Rows.where(:startup, "blocks_on_peer", filters)
      |> Enum.map(&hd/1)
      |> Enum.uniq()
      |> Enum.sort()
    end

    # The rpc, the lock and the call to a later sibling hold the start
    # only before the ack.
    assert heads.(kind: "remote") == ["Argus.Test.Fixtures.InitAck.RpcBefore:init/1"]

    assert heads.(kind: ["global", "global_assumed"]) == [
             "Argus.Test.Fixtures.InitAck.LockBefore:init/1"
           ]

    assert heads.(phase: "init", kind: "call", ordering: "later") == [
             "Argus.Test.Fixtures.InitAck.CallsBefore"
           ]

    # The startup window does not end at the ack: the supervisor has moved
    # on to start Later, and the call races it (a warning, not the
    # deadlock).
    assert heads.(phase: "init", kind: "window_call", ordering: "later") == [
             "Argus.Test.Fixtures.InitAck.CallsAfter"
           ]

    # After the ack they are the server's waits, and blocking's findings.
    {:ok, b} =
      Memo.analyze(
        [InitAck.RpcBefore, InitAck.RpcAfter, InitAck.LockBefore, InitAck.LockAfter],
        :blocking
      )

    waits = fn kind ->
      b
      |> Rows.where(:blocking, "unbounded_wait", kind: kind, drop: [:peer, :permille])
      |> Enum.map(&hd/1)
      |> Enum.uniq()
    end

    assert waits.("rpc") == ["Argus.Test.Fixtures.InitAck.RpcAfter:init/1"]
    assert waits.("global") == ["Argus.Test.Fixtures.InitAck.LockAfter:init/1"]
  end

  test "a call a task init/1 starts makes to a later sibling is no deadlock, but races it" do
    alias InitRecv.TaskCalls

    {:ok, r} =
      Memo.analyze([TaskCalls.Sup, TaskCalls.Early, TaskCalls.Later], :startup)

    assert Rows.where(r, :startup, "blocks_on_peer", phase: "init", kind: "call") == []

    # The task runs while the supervisor goes on to start Later.
    assert r
           |> Rows.where(:startup, "blocks_on_peer", phase: "init", kind: "window_call")
           |> Enum.map(&hd/1)
           |> Enum.uniq() == ["Argus.Test.Fixtures.InitRecv.TaskCalls.Early"]
  end

  test "a cast a task init/1 starts makes to a later sibling races its start" do
    alias InitRecv.TaskCasts

    {:ok, r} =
      Memo.analyze([TaskCasts.Sup, TaskCasts.InTask, TaskCasts.Direct, TaskCasts.Later], :startup)

    # Review 2, item 11: InTask's task runs at once, while the supervisor
    # goes on to start Later, and its cast to the unregistered name is
    # dropped; 87209008 had made it the task's own and quiet.
    assert r
           |> Rows.where(:startup, "blocks_on_peer", phase: "init", kind: "cast")
           |> Enum.map(&hd/1)
           |> Enum.uniq()
           |> Enum.sort() == [
             "Argus.Test.Fixtures.InitRecv.TaskCasts.Direct",
             "Argus.Test.Fixtures.InitRecv.TaskCasts.InTask"
           ]
  end

  test "a connect, a lock or a supervisor call in a task init/1 starts holds nothing" do
    {:ok, r} = Memo.analyze([InitRecv.SpawnsWork], :startup)

    assert Rows.where(r, :startup, "unbounded_effect_in_init",
             kind: "connect",
             drop: [:peer, :permille]
           ) == []

    assert Rows.where(r, :startup, "blocks_on_peer", kind: ["global", "sup"]) == []

    # The lock still waits without bound in the task, which blocking says.
    {:ok, b} = Memo.analyze([InitRecv.SpawnsWork], :blocking)

    assert [["Argus.Test.Fixtures.InitRecv.SpawnsWork:connect/2" | _]] =
             Rows.where(b, :blocking, "unbounded_wait", kind: "global", drop: [:peer, :permille])
  end
end
