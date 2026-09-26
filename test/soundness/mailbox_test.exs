defmodule Argus.Soundness.MailboxTest do
  @moduledoc """
  Mailbox bugs a suppression once silenced, and their adversarial
  neighbours: each program is solved alone and must keep its finding at
  the severity the rule gave it before the suppression
  (`Argus.Test.Soundness`).
  """
  use ExUnit.Case, async: true

  import Argus.Test.Soundness, only: [fired: 2]

  alias Argus.Test.Soundness.Mailbox, as: M

  @ref_dropped "Server drops the ref of a monitor it establishes"
  @timed_wait "Monitor left live after a wait times out"

  describe "a :DOWN wait is the clause that takes it, not the receive (review 2, item 5)" do
    test "a reply-or-:DOWN wait leaves the dropped ref live on the reply path" do
      assert {:info, @ref_dropped, {M.ReplyOrDown, :handle_call, 3}} in fired(
               [M.ReplyOrDown],
               :mailbox
             )
    end

    test "so does the same wait after a helper that monitors" do
      assert {:info, @ref_dropped, {M.ReplyOrDownCaller, :ask, 2}} in fired(
               [M.ReplyOrDownCaller],
               :mailbox
             )
    end

    test "a helper that waits so is no collector" do
      assert {:info, @ref_dropped, {M.HelperReplyOrDown, :handle_call, 3}} in fired(
               [M.HelperReplyOrDown],
               :mailbox
             )
    end

    test "a timed receive's :DOWN clause does not cover its `after`" do
      found = fired([M.TimedGivesUp], :mailbox)
      assert {:info, @ref_dropped, {M.TimedGivesUp, :handle_call, 3}} in found
      assert {:error, @timed_wait, {M.TimedGivesUp, :handle_call, 3}} in found
    end

    test "a helper that waits on one branch, and does not loop, is no collector" do
      assert {:info, @ref_dropped, {M.MaybeWaits, :handle_call, 3}} in fired(
               [M.MaybeWaits],
               :mailbox
             )
    end

    test "a clause body the compiler may share with the :DOWN clause's takes no :DOWN" do
      assert {:info, @ref_dropped, {M.SameBody, :handle_call, 3}} in fired([M.SameBody], :mailbox)
    end
  end

  @unflushed "Timer cancelled without flushing its message"
  @loop "Periodic timer loop armed again while it runs"

  describe "a flush is its own caller's (review 2, item 19)" do
    test "a helper's cancel two callers make, one of which flushes" do
      assert {:warning, @unflushed, {M.FlushTwoCallers, :cancel_check, 1}} in fired(
               [M.FlushTwoCallers],
               :mailbox
             )
    end

    test "a ref handed down to a cancel helper by two callers, one of which flushes" do
      assert {:warning, @unflushed, {M.HandsDown, :stop, 1}} in fired([M.HandsDown], :mailbox)
    end
  end

  describe "a periodic timer loop armed again while it runs (review 2, item 21)" do
    for {mod, entry} <- [
          {ContinueLoop, {:handle_cast, 2}},
          {ContinueHelper, {:handle_cast, 2}},
          {NilGuardRunning, {:handle_call, 3}},
          {TruthyGuard, {:handle_call, 3}},
          {HelperCancelsElsewhere, {:handle_cast, 2}},
          {BranchCancel, {:handle_cast, 2}}
        ] do
      @mod Module.concat(M, mod)
      @entry entry
      test "#{inspect(mod)}" do
        {f, a} = @entry
        assert {:warning, @loop, {@mod, f, a}} in fired([@mod], :mailbox)
      end
    end
  end

  describe "review 2, items 23, 25, 26, 33 and 34" do
    test "the program's own async_nolink under a library's handle_info/2 (item 23)" do
      assert {:warning, "async_nolink task's messages have no handle_info clause",
              {M.NolinkWarmer, :execute, 1}} in fired([M.NolinkWarmer], :mailbox)
    end

    test "a monitor on what a lookup-or-start wrapper returns is no owned worker (item 25)" do
      assert {:info, @ref_dropped, {M.Tracker, :handle_call, 3}} in fired(
               [M.Session, M.Sessions, M.Tracker],
               :mailbox
             )
    end

    test "one caller of a ref-returning helper drops the ref (item 26)" do
      assert {:info, @ref_dropped, {M.MixedCallers, :watch, 1}} in fired(
               [M.MixedCallers],
               :mailbox
             )
    end

    test "Enum.map of monitors whose refs are dropped (item 26)" do
      assert {:info, @ref_dropped, {M.MapDropped2, :"-handle_call/3-fun-0-", 1}} in fired(
               [M.MapDropped2],
               :mailbox
             )
    end

    test "a {:system, x} 2-tuple is a message, not :sys's envelope (item 33)" do
      assert {:error, "No handle_info/2 clause for a message the server is sent",
              {M.EnvelopeSystem2, :reload, 1}} in fired([M.EnvelopeSystem2], :mailbox)
    end

    test "one state's :info clause is no catch-all for the machine (item 34)" do
      assert {:error, "No clause for a message a gen_statem is sent",
              {M.TwoStateInfo, :handle_event, 4}} in fired([M.TwoStateInfo], :mailbox)
    end
  end

  describe "a monitor's :DOWN, whatever reason the runtime gives it (partial_handler retired)" do
    alias Argus.Test.Soundness.Witness, as: W

    @crash "No handle_info/2 clause for a message the server is sent"

    test "a clause for the :normal reason alone" do
      assert {:warning, @crash, {W.DownOnlyNormal, :handle_call, 3}} in fired(
               [W.DownOnlyNormal],
               :mailbox
             )
    end

    test "a guard on the reason" do
      assert {:warning, @crash, {W.DownGuardIn, :handle_cast, 2}} in fired(
               [W.DownGuardIn],
               :mailbox
             )
    end

    test "a pattern on the reason, the monitor taken in a helper on the server's stack" do
      assert {:warning, @crash, {W.Watch, :watch, 1}} in fired(
               [W.DownShutdownOnly, W.Watch],
               :mailbox
             )
    end

    test "a port's :DOWN under a clause pinned to its ref and the :process type" do
      assert {:warning, @crash, {W.PortDownPinned, :init, 1}} in fired(
               [W.PortDownPinned],
               :mailbox
             )
    end
  end

  test "lists:map/2 of monitors whose refs are dropped (item 26)" do
    assert Enum.any?(fired([M.ListsMapDropped], :mailbox), &match?({:info, @ref_dropped, _}, &1))
  end

  test "a 3-tuple tagged :\"$gen_cast\" is a message (item 33)" do
    assert {:error, "No handle_info/2 clause for a message the server is sent",
            {M.EnvelopeCast3, :run, 0}} in fired([M.EnvelopeCast3], :mailbox)
  end

  test "a helper that reads state.interval re-arms on every path (suspected, confirmed)" do
    assert {:warning, @loop, {M.DotHelperLoop, :handle_cast, 2}} in fired(
             [M.DotHelperLoop],
             :mailbox
           )
  end

  test "a timed :DOWN wait whose after raises keeps the timed-wait finding" do
    assert {:error, @timed_wait, {M.RaisingAfter, :await_downfall, 1}} in fired(
             [M.RaisingAfter],
             :mailbox
           )
  end
end
