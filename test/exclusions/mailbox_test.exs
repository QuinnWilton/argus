defmodule Argus.Exclusions.MailboxTest do
  @moduledoc """
  Regression cases for mailbox exclusions. Suppressed cases have a reported
  twin or supporting row so missing extraction cannot make the check pass.
  Fixtures: test/fixtures/exclusions/mailbox.ex.
  """
  use ExUnit.Case, async: true

  import Argus.Test.Soundness, only: [fired: 2]

  alias Argus.Souffle
  alias Argus.Test.Batch
  alias Argus.Test.Rows
  alias Excl.Mailbox, as: M

  @arms_under_test [
    M.ArmsUnderTest.Heartbeat,
    M.ArmsUnderTest.Pauser,
    M.ArmsUnderTest.HeartbeatTestSupport
  ]
  @tagged_cancel [M.TaggedCancelUntaggedArm.Configure, M.TaggedCancelUntaggedArm.Ticker]
  @untagged_cancel [M.UntaggedCancelTaggedArm.Stop, M.UntaggedCancelTaggedArm.Ticker]
  @test_only_flush [
    M.TestOnlyFlush.WriteBuffer,
    M.TestOnlyFlush.BufferTestSupport,
    Mix.Tasks.Excl.Mailbox.TestOnlyFlush.Drain
  ]

  # Every test reads its fixtures' rows from one solve of them all
  # (`Argus.Test.Batch`; ARGUS_VERIFY_BATCH=1 checks each slice against a
  # solve of its own).
  @batched [
    [M.TerminateDeadline.Pool],
    [M.CallDeadline.Pool],
    @arms_under_test,
    [M.YieldInClosure.Fanout],
    [M.AwaitInClosure.Thumbs],
    [M.OnceClauseStartsLoop.Cache],
    [M.DrainReentersItself.Drainer],
    @tagged_cancel,
    @untagged_cancel,
    [M.LoopDropsAndKeeps.Reloader],
    [M.ArmsWhenEmpty.Producer],
    [M.ArmsAlways.Producer],
    @test_only_flush
  ]

  setup_all do
    %{batch: Batch.solve(:mailbox, @batched)}
  end

  defp results(%{batch: batch}, set) do
    unless Souffle.available?(), do: flunk("souffle not installed")
    {:ok, results} = Batch.analyze(batch, set)
    results
  end

  # {cancelling function, key, message} of each unflushed cancel.
  defp unflushed(ctx, set) do
    for [cancel, key, message] <-
          Rows.where(results(ctx, set), :mailbox, "timer_cancel_without_flush",
            drop: [:mod, :arm, :cancel_site, :arm_site]
          ),
        do: {short(cancel), key, message}
  end

  # {message, entry function, kept under} of each re-armed loop.
  defp rearmed(ctx, set) do
    for [message, entry, keeps] <-
          Rows.where(results(ctx, set), :mailbox, "timer_loop_rearmed",
            drop: [:mod, :site, :arm_site, :loop_site]
          ),
        do: {message, short(entry), keeps}
  end

  # {owner function, kind} of each task result defect.
  defp task_defects(ctx, set) do
    for [func, kind] <-
          Rows.where(results(ctx, set), :mailbox, "task_result_defect", drop: [:site]),
        do: {short(func), kind}
  end

  defp short(func), do: func |> String.split(":") |> List.last()

  describe "a timer cancelled without a flush" do
    # mailbox.dl, timer_cancel_without_flush: !runs_only_on_the_way_out(cancel).
    test "a local deadline terminate/2 arms and cancels around a drain", ctx do
      assert unflushed(ctx, [M.TerminateDeadline.Pool]) == []

      assert unflushed(ctx, [M.CallDeadline.Pool]) ==
               [{"handle_call/3", "", ":drain_deadline"}]
    end

    # mailbox.dl, arm_off_test: !site_under_test(arm_site).
    test "kept: every re-arm under the key is one only test helpers request", ctx do
      assert {"handle_cast/2", ":timer", ":beat"} in unflushed(ctx, @arms_under_test)

      assert [["Excl.Mailbox.ArmsUnderTest.HeartbeatTestSupport", "test_support"]] =
               Rows.where(results(ctx, @arms_under_test), :mailbox, "tooling", drop: [:permille])
    end

    # test_code.dl, runs_outside_tests: !test_code(g).
    test "a cancel only test support reaches, through a Mix task, stays test-only", ctx do
      # The finding stays with the product's cancel in handle_cast/2; the
      # one in handle_call/3 only test support reaches.
      cancels = for {cancel, _, _} <- unflushed(ctx, @test_only_flush), uniq: true, do: cancel
      assert cancels == ["handle_cast/2"]

      assert [["Excl.Mailbox.TestOnlyFlush.WriteBuffer:handle_call/3"]] =
               Rows.where(results(ctx, @test_only_flush), :mailbox, "timer_cancel_under_test",
                 drop: [:mod, :key, :site]
               )
    end
  end

  describe "a task's result, owned by the named function" do
    # mailbox.dl, task_result_defect: !closure_def(_, owner), in the yield
    # rule and in the library rule (the task is linked too).
    test "a linked task started and yielded inside an Enum.map fn", ctx do
      defects = task_defects(ctx, [M.YieldInClosure.Fanout])
      assert {"fetch_all/1", "yield_linked"} in defects
      assert Enum.all?(defects, &match?({"fetch_all/1", _}, &1))
    end

    # mailbox.dl, task_result_defect: !closure_def(_, owner), the library
    # rule.
    test "a linked task started and awaited inside an Enum.map fn", ctx do
      assert task_defects(ctx, [M.AwaitInClosure.Thumbs]) ==
               [{"resize_all/1", "linked_in_library"}]
    end
  end

  describe "a periodic timer loop armed again" do
    # mailbox.dl, second_arm: !once_clause(c, e).
    test "by a clause that runs once and calls the loop's clause to start it", ctx do
      assert rearmed(ctx, [M.OnceClauseStartsLoop.Cache]) == []
      assert rearmed(ctx, [M.DrainReentersItself.Drainer]) == [{":drain", "handle_info/2", ""}]
    end

    # mailbox.dl, same_clause: !has_clause(s).
    test "kept: a tagged clause's cancel does not stop a struct clause's arm", ctx do
      assert rearmed(ctx, @tagged_cancel) == [{":tick", "handle_call/3", ":timer"}]
    end

    # mailbox.dl, same_clause: !has_clause(t).
    test "kept: a struct clause's cancel does not stop a tagged clause's arm", ctx do
      assert rearmed(ctx, @untagged_cancel) == [{":tick", "handle_call/3", ":timer"}]
    end

    # mailbox.dl, timer_loop_rearmed: !loop_drops_ref(mod, lit, _).
    test "a loop that drops its ref is reported once, not again under a key", ctx do
      assert rearmed(ctx, [M.LoopDropsAndKeeps.Reloader]) == [{":reload", "handle_cast/2", ""}]
    end

    # mailbox.dl, timer_loop_rearmed: !arms_when_empty(e, c, key).
    test "only while its key is empty, when no loop runs", ctx do
      assert rearmed(ctx, [M.ArmsWhenEmpty.Producer]) == []
      assert rearmed(ctx, [M.ArmsAlways.Producer]) == [{":poll", "handle_cast/2", ":timer"}]
    end
  end

  # Real bugs a removed exclusion used to hide: each is solved alone and
  # must keep its finding (`Argus.Test.Soundness`).
  describe "real bugs a removed exclusion used to hide" do
    test "a clause that arms and cancels a local watchdog for its own message" do
      assert {:warning, "Timer cancelled without flushing its message",
              {M.OwnClauseWatchdog.Poller, :handle_info, 2}} in fired(
               [M.OwnClauseWatchdog.Poller],
               :mailbox
             )
    end

    test "a loop clause that runs itself again directly while a backlog is left" do
      assert {:warning, "Periodic timer loop armed again while it runs",
              {M.DrainReentersItself.Drainer, :handle_info, 2}} in fired(
               [M.DrainReentersItself.Drainer],
               :mailbox
             )
    end
  end
end
