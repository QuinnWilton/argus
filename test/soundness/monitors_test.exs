defmodule Argus.Soundness.MonitorsTest do
  @moduledoc """
  The monitor-leak model's narrowings (docs/analyses/mailbox.md#repeated-live-monitors),
  each with the adversarial shapes it must not excuse: every program is solved alone and
  must keep its finding (`Argus.Test.Soundness`).

  A monitor piles up when code that runs again takes it (the run
  repeats), on a process the run did not start (it can meet that process
  again), without releasing it on some way out, and one witness shows the
  monitor before is still live: a wait, a dropped record, a thrown-away
  ref taken without asking the state.
  """
  use ExUnit.Case, async: true

  import Argus.Test.Soundness, only: [fired: 2]

  alias Argus.Test.Memo
  alias Argus.Test.Soundness.Monitors, as: M

  @wait {:warning, "Monitor left live each time a wait returns"}
  @ended {:warning, "Entry dropped while its process stays monitored"}
  @dropped {:info, "Monitor taken again with its ref thrown away"}

  defp assert_fires(modules, {severity, title}, mfa) do
    found = fired(modules, :mailbox)

    assert {severity, title, mfa} in found,
           "expected #{inspect({severity, title, mfa})} in:\n" <>
             Enum.map_join(found, "\n", &inspect/1)
  end

  describe "the run repeats: once code does not excuse code that also runs again" do
    test "a helper init/1 and a handler share" do
      assert_fires([M.SharedByInitAndHandler], @dropped, {M.SharedByInitAndHandler, :connect, 1})
    end

    test "a gen_statem's event handler" do
      assert_fires(
        [M.StateFunctionMonitor],
        @dropped,
        {M.StateFunctionMonitor, :handle_event, 4}
      )
    end

    test "a spawned receive loop" do
      assert_fires([M.HandRolledLoop], @dropped, {M.HandRolledLoop, :loop, 1})
    end
  end

  describe "the process is one the run can meet again: a start does not excuse" do
    test "a start of a worker beside a monitor of the caller" do
      assert_fires(
        [M.StartsThenMonitorsCaller],
        @dropped,
        {M.StartsThenMonitorsCaller, :handle_call, 3}
      )
    end

    test "a named start that answers the running process when already started" do
      assert_fires([M.StartOrFind, M.Room], @dropped, {M.StartOrFind, :handle_call, 3})
    end

    test "a worker another callback started and the state keeps" do
      assert_fires([M.MonitorsStoredWorker], @dropped, {M.MonitorsStoredWorker, :handle_info, 2})
    end
  end

  describe "the process is one the run can meet again: a wrapper excuses only a start's answer" do
    test "a wrapper that looks the process up first" do
      assert_fires(
        [M.MonitorsLookupWrapper, M.Wrappers, M.Room],
        @dropped,
        {M.MonitorsLookupWrapper, :handle_call, 3}
      )
    end

    test "a wrapper that re-wraps the already-started pid as {:ok, pid}" do
      assert_fires(
        [M.MonitorsAlreadyStartedWrapper, M.Wrappers, M.Room],
        @dropped,
        {M.MonitorsAlreadyStartedWrapper, :handle_call, 3}
      )
    end

    test "a wrapper that hands back its parameter on one clause" do
      assert_fires(
        [M.MonitorsParameterWrapper, M.Wrappers, M.Room],
        @dropped,
        {M.MonitorsParameterWrapper, :handle_call, 3}
      )
    end

    test "a function named like a start that answers another server's reply" do
      assert_fires(
        [M.MonitorsReplyWrapper, M.Wrappers, M.Room],
        @dropped,
        {M.MonitorsReplyWrapper, :handle_call, 3}
      )
    end
  end

  describe "released by the run: a release on some way out does not excuse" do
    test "a demonitor on the answer path only" do
      assert_fires([M.DemonitorOnOnePath], @wait, {M.DemonitorOnOnePath, :ask, 1})
    end

    test "a demonitor of the other monitor" do
      assert_fires([M.DemonitorsAnotherRef], @wait, {M.DemonitorsAnotherRef, :ask, 2})
    end

    test "a helper handed the ref that releases it on one way out" do
      assert_fires([M.HelperReleasesOnOnePath], @wait, {M.HelperReleasesOnOnePath, :stop, 1})
    end

    test "a demonitor without :flush on every way out releases it" do
      refute Enum.any?(
               fired([M.PlainDemonitor], :mailbox),
               &match?({_, _, {M.PlainDemonitor, _, _}}, &1)
             )
    end
  end

  describe "dropped: a test does not excuse unless it asks the state first" do
    test "a test of the request" do
      assert_fires([M.GuardOnRequest], @dropped, {M.GuardOnRequest, :handle_call, 3})
    end

    test "a clause that reaches the same helper without asking" do
      assert_fires([M.GuardInOtherClause], @dropped, {M.GuardInOtherClause, :watch, 1})
    end

    test "a test of the state made after the monitor" do
      assert_fires([M.GuardAfterMonitor], @dropped, {M.GuardAfterMonitor, :handle_call, 3})
    end
  end

  describe "ended: a drop is the monitor's own end only in its :DOWN clause" do
    test "a drop a helper makes for an unsubscribe" do
      assert_fires([M.DropInHelper], @ended, {M.DropInHelper, :handle_call, 3})
    end

    test "a reset in the :DOWN clause of another monitor" do
      assert_fires([M.ResetOnConnectionDown], @ended, {M.ResetOnConnectionDown, :handle_call, 3})
    end

    test "a row deleted by a cast" do
      assert_fires([M.TableDeleteOnCast], @ended, {M.TableDeleteOnCast, :handle_call, 3})
    end

    test "a drop in a gen_statem clause of the same type and another content" do
      assert_fires([M.StatemUnwatchDrops], @ended, {M.StatemUnwatchDrops, :handle_event, 4})
    end

    test "a reset in another :internal clause of a gen_statem" do
      assert_fires([M.StatemInternalReset], @ended, {M.StatemInternalReset, :handle_event, 4})
    end

    test "a reset in a gen_statem's :DOWN clause for another monitor" do
      assert_fires([M.StatemOtherDownResets], @ended, {M.StatemOtherDownResets, :handle_event, 4})
    end

    test "a drop in another clause of a state function" do
      assert_fires([M.StateFunctionUnwatch], @ended, {M.StateFunctionUnwatch, :ready, 3})
    end

    test "a reset of the field that holds the ref, beside a field it does not" do
      assert_fires([M.ResetsItsRecord], @ended, {M.ResetsItsRecord, :handle_call, 3})
    end

    test "a removal from the field that holds the pid, the ref thrown away" do
      assert_fires([M.RemovesFromItsRecord], @ended, {M.RemovesFromItsRecord, :handle_call, 3})
    end

    test "a gen_statem's removal from the map that holds the ref" do
      assert_fires([M.StatemDropsOwnerMon], @ended, {M.StatemDropsOwnerMon, :handle_event, 4})
    end

    test "a reset of the map a helper that monitors handed back" do
      assert_fires(
        [M.ResetsHelperKeptMap, Argus.Test.Fixtures.MonitorLeak.Monitors],
        @ended,
        {Argus.Test.Fixtures.MonitorLeak.Monitors, :add, 3}
      )
    end

    test "a reset of what two layers of helpers handed back, taken out of an {:ok, map}" do
      assert_fires(
        [M.ResetsTwoLayersDown, M.Registry, Argus.Test.Fixtures.MonitorLeak.Monitors],
        @ended,
        {Argus.Test.Fixtures.MonitorLeak.Monitors, :add, 3}
      )
    end

    test "a reset of the element of a fold's answer that holds the refs" do
      assert_fires(
        [M.FoldResetsChecks],
        @ended,
        {M.FoldResetsChecks, :"-handle_call/3-fun-0-", 2}
      )
    end

    test "a delete of the table that holds the ref, beside one that does not" do
      assert_fires([M.DeletesItsTable], @ended, {M.DeletesItsTable, :handle_call, 3})
    end

    test "a drop that demonitors is the release" do
      refute Enum.any?(
               fired([M.DropAndDemonitor], :mailbox),
               &match?({_, _, {M.DropAndDemonitor, _, _}}, &1)
             )
    end
  end

  # A monitoring run that asks a store before it monitors is taken again
  # on the same process only once that store loses it; a field reset
  # forgets a monitor only when nothing else the server keeps holds its
  # ref. The quiet shapes are at the end of test/fixtures/monitor_fixture.ex
  # and in test/fixtures/erl/mon_asks_pool.erl.
  describe "ended: the store the run asks, and the reset that forgets the ref" do
    test "a removal from the store asked, beside a record the ask does not read" do
      assert_fires([:mon_asks_pool_drops], @ended, {:mon_asks_pool_drops, :handle_cast, 2})
      assert_fires([M.AsksWatchedDrops], @ended, {M.AsksWatchedDrops, :handle_call, 3})
    end

    test "a delete from the table asked" do
      assert_fires([M.AsksItsTableDrops], @ended, {M.AsksItsTableDrops, :handle_call, 3})
    end

    test "an ask about another key is no ask about the process" do
      assert_fires([M.AsksAnotherKey], @ended, {M.AsksAnotherKey, :handle_cast, 2})
    end

    test "an ask after the monitor gates nothing" do
      assert_fires([M.AsksAfterMonitoring], @ended, {M.AsksAfterMonitoring, :handle_cast, 2})
    end

    test "a drop of the store asked, though it holds no ref" do
      assert_fires(
        [M.AsksStoreFilledElsewhere],
        @ended,
        {M.AsksStoreFilledElsewhere, :handle_call, 3}
      )
    end

    test "a reset of the one record of a fold's refs to undefined" do
      assert_fires(
        [:mon_reset_config],
        @ended,
        {:mon_reset_config, :"-handle_call/3-fun-0-", 2}
      )
    end

    test "a reset of the field that holds the ref, beside one that holds the pid" do
      assert_fires([M.ListenersKeepPidOnly], @ended, {M.ListenersKeepPidOnly, :handle_call, 3})
      assert_fires([M.ResetsOwnerMon], @ended, {M.ResetsOwnerMon, :handle_call, 3})
    end

    test "a reset of the pid when the ref was thrown away" do
      assert_fires(
        [M.ResetsPidRefThrownAway],
        @ended,
        {M.ResetsPidRefThrownAway, :handle_call, 3}
      )
    end

    test "a reset in a helper the clause returns through" do
      assert_fires([M.ResetsThroughHelper], @ended, {M.ResetsThroughHelper, :handle_call, 3})
    end
  end

  # "runs again from here" names the callbacks the finding's own walk
  # comes from. A handle_continue/2 clause init/1 continues to calls the
  # helper once (once_site, runs.dl), so it is no such callback, though
  # handle_continue/2 is one that runs again where a handler continues to
  # it.
  describe "the callbacks that run it again" do
    for {mod, witness, func} <- [
          {M.WatchOnceAndAgain, @dropped, :watch},
          {M.AskOnceAndAgain, @wait, :ask}
        ] do
      test "#{inspect(mod)}: not the once clause that also reaches it" do
        mod = unquote(mod)
        {severity, title} = unquote(witness)
        assert_fires([mod], {severity, title}, {mod, unquote(func), 1})

        assert {:ok, %{findings: findings}} = Memo.run_analyses([mod], analyses: [:mailbox])
        assert [finding] = Enum.filter(findings, &(&1.title == title))

        runs =
          for %{label: "runs again from here", mfa: mfa} <- finding.related, do: mfa

        assert runs == [{mod, :handle_call, 3}]
      end
    end
  end
end
