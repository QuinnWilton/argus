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
end
