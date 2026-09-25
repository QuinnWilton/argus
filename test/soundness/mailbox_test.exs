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
end
