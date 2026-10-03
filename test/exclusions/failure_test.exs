defmodule Argus.Exclusions.FailureTest do
  @moduledoc """
  Regression cases for failure exclusions. Suppressed cases have a reported
  twin or supporting row so missing extraction cannot make the check pass.
  Fixtures: test/fixtures/exclusions/failure.ex.
  """
  use ExUnit.Case, async: true
  @moduletag :souffle

  alias Argus.Test.Batch
  alias Argus.Test.Rows
  alias Excl.Failure, as: F

  # Every test reads its fixtures' rows from one solve of them all
  # (`Argus.Test.Batch`; ARGUS_VERIFY_BATCH=1 checks each slice against a
  # solve of its own).
  @batched [
    [F.RemoteProbe.Bare],
    [F.RemoteProbe.HelperRescues],
    [F.ErpcTransport.Unwrapped],
    [F.ErpcTransport.CaughtByTag],
    [F.ErpcBool.Bare],
    [F.ErpcBool.RescuesAll],
    [F.ErpcBool.CatchesTag],
    [F.ErpcBool.CatchesTagAroundIf],
    [F.WatchedStart.Unwatched],
    [F.WatchedStart.Monitored],
    [F.BareCover.Client],
    [F.StartChildBelief.Mailer],
    [F.StartChildBelief.UncappedMailer]
  ]

  setup_all do
    %{batch: Batch.solve(:failure, @batched)}
  end

  # The set's rows of `relation`, with the `drop` columns removed.
  defp rows(%{batch: batch}, set, relation, drop) do
    {:ok, results} = Batch.analyze(batch, set)
    Rows.where(results, :failure, relation, drop: drop)
  end

  # {function, kind, shape} of each unhandled failure.
  defp unhandled(ctx, set) do
    for [func, kind, shape] <- rows(ctx, set, "unhandled_failure", [:site, :span_end]),
        do: {short(func), kind, shape}
  end

  defp probes(ctx, set) do
    for [func, api, kind] <- rows(ctx, set, "remote_pid_probe", [:anchor, :site, :bif]),
        do: {short(func), api, kind}
  end

  defp orphans(ctx, set) do
    for [func, kind] <- rows(ctx, set, "orphan_process", [:site, :target, :callback]),
        do: {short(func), kind}
  end

  # A function's name and arity, without its module.
  defp short(func), do: func |> String.split(":") |> List.last()

  describe "a remote pid probed" do
    # failure.dl, remote_pid_probe: probe_raise_escapes (Escape).
    test "through a helper that rescues the ArgumentError itself", ctx do
      assert probes(ctx, [F.RemoteProbe.HelperRescues]) == []

      assert probes(ctx, [F.RemoteProbe.Bare]) ==
               [{"cleanup/1", ":global.whereis_name/1", "lookup"}]
    end
  end

  describe "an :erpc call's failure" do
    # failure.dl, unhandled_failure: !catch_tag(id, func, "error", ":erpc").
    test "a catch that takes {:erpc, _} before unwrapping the remote exception", ctx do
      assert unhandled(ctx, [F.ErpcTransport.CaughtByTag]) == []

      assert unhandled(ctx, [F.ErpcTransport.Unwrapped]) ==
               [{"get/2", "erpc_transport", ""}]
    end

    # failure.dl, unhandled_failure: !catches_class(f, "error").
    test "a boolean :erpc call under a rescue of every exception", ctx do
      assert unhandled(ctx, [F.ErpcBool.RescuesAll]) == []
      assert unhandled(ctx, [F.ErpcBool.Bare]) == [{"alive?/2", "erpc", "boolean"}]
    end

    # failure.dl, unhandled_failure: !catch_tag(_, f, "error", ":erpc").
    test "a boolean :erpc call, used or branched on, under a catch of {:erpc, _}", ctx do
      assert unhandled(ctx, [F.ErpcBool.CatchesTag]) == []
      assert unhandled(ctx, [F.ErpcBool.CatchesTagAroundIf]) == []
      assert unhandled(ctx, [F.ErpcBool.Bare]) == [{"alive?/2", "erpc", "boolean"}]
    end
  end

  describe "a process started with :proc_lib.start" do
    # failure.dl, orphan_process: !watched_spawn(id).
    test "its starter monitors it once it is up", ctx do
      assert orphans(ctx, [F.WatchedStart.Monitored]) == []
      assert orphans(ctx, [F.WatchedStart.Unwatched]) == [{"start_worker/0", "start"}]
    end
  end

  describe "a deviant site is reported once" do
    # failure.dl, bare_cover: !try_covers(_, _, site, _).
    test "a call covered by a local try that takes nothing, whose caller rescues something else",
         ctx do
      covers =
        for [func, _callee, _belief, _agree, _deviate, _target, _raises, cover, _caught] <-
              rows(ctx, [F.BareCover.Client], "inconsistent_handling", [:site]),
            do: {short(func), cover}

      assert covers == [{"fetch/1", "try"}]
    end

    # failure.dl, ignored_where_most_are_used:
    # !unchecked_result(func, site, _, _).
    test "a dropped start_child result is the unchecked result's, not a second inconsistency",
         ctx do
      assert rows(ctx, [F.StartChildBelief.Mailer], "inconsistent_handling", []) == []

      assert [["Excl.Failure.StartChildBelief.Mailer:notify/1", "Task.Supervisor.start_child"]] =
               rows(ctx, [F.StartChildBelief.Mailer], "unchecked_result", [:site, :name])
    end

    # failure.dl, reported_elsewhere: starts_supervised_task, !start_may_fail.
    test "a dropped start_child result under no cap is neither rule's", ctx do
      assert rows(ctx, [F.StartChildBelief.UncappedMailer], "inconsistent_handling", []) == []
      assert rows(ctx, [F.StartChildBelief.UncappedMailer], "unchecked_result", []) == []
    end
  end
end
