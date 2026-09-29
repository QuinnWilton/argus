defmodule Argus.Soundness.MonitorsTest do
  @moduledoc """
  The monitor-leak model's narrowings (docs/design/monitor-leaks.md),
  each with the adversarial shapes it must not excuse: every program is
  solved alone and must keep its finding (`Argus.Test.Soundness`).

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

    test "a drop that demonitors is the release" do
      refute Enum.any?(
               fired([M.DropAndDemonitor], :mailbox),
               &match?({_, _, {M.DropAndDemonitor, _, _}}, &1)
             )
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
