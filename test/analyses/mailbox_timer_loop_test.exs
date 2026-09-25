defmodule Argus.Analyses.MailboxTimerLoopTest do
  use ExUnit.Case, async: true

  alias Argus.Souffle
  alias Argus.Test.Fixtures.TimerLoop, as: T
  alias Argus.Test.Memo

  # Every fixture is its own server, and the rule never joins across
  # modules, so the set is solved once and each test reads its rows.
  @all [
    T.ReloadLoop,
    T.SharedScheduler,
    T.SelfKick,
    T.KeptRefRearm,
    T.DirectKick,
    T.InitOnly,
    T.CancelFirst,
    T.IdempotentLoop,
    T.RefTagged,
    T.ContinueArm,
    T.OtherProcess,
    T.OneShot,
    T.RetryLoop,
    T.AfterJoin,
    T.Redispatch,
    T.SameTagResend,
    T.CastFromInit,
    T.CastFromInitAndApi,
    :timer_loop_reloader,
    :timer_loop_resend,
    :timer_loop_domain_db
  ]

  setup_all do
    unless Souffle.available?(), do: flunk("souffle not installed")
    assert {:ok, results} = Memo.analyze(@all, :mailbox)
    %{rows: Map.get(results, "timer_loop_rearmed", [])}
  end

  defp reported(rows) do
    rows
    |> Enum.map(fn [mod, message, entry, _site, _arm, _loop, keeps] ->
      {mod |> String.replace("Argus.Test.Fixtures.TimerLoop.", ""), message,
       entry |> String.split(":") |> List.last(), keeps}
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  test "a second path arms a running loop's message again", %{rows: rows} do
    assert reported(rows) == [
             # A loop that drops its ref cannot be stopped: the config
             # change's cancel of the ref init/1 kept is too late.
             {":timer_loop_reloader", ":reload", "handle_cast/2", ""},
             # A first load init/1 casts, that the API casts too.
             {"CastFromInitAndApi", ":refresh", "handle_cast/2", ""},
             # A cast that runs the loop's clause with its message.
             {"DirectKick", ":poll", "handle_cast/2", ""},
             # One clause re-arms without cancelling the kept ref first,
             # the other cancels.
             {"KeptRefRearm", ":beat", "handle_info/2", ":beat_ref"},
             {"ReloadLoop", ":reload", "handle_cast/2", ""},
             # A kick sent to self() while the loop's timer is pending.
             {"SelfKick", ":report", "handle_cast/2", ""},
             # The reset stores over the ref the loop keeps.
             {"SharedScheduler", ":tick", "handle_cast/2", ":timer"}
           ]
  end

  test "the finding points at the second arm, with the loop's re-arm beside it", %{rows: rows} do
    for [_mod, _message, _entry, site, arm_site, loop_site, _keeps] <- rows do
      assert {:ok, _} = Argus.InstrId.parse(site)
      assert {:ok, _} = Argus.InstrId.parse(arm_site)
      assert {:ok, _} = Argus.InstrId.parse(loop_site)
    end

    # A loop re-armed through a helper points at the helper's arm.
    assert [[_, _, _, _, _, loop_site, _]] =
             Enum.filter(rows, &(hd(&1) == inspect(T.SharedScheduler)))

    assert {:ok, %{func: "schedule"}} = Argus.InstrId.parse(loop_site)

    # The reconnect clause is the one reported, not the clause that
    # cancels first.
    assert [[_, _, _, site, _, _, _]] = Enum.filter(rows, &(hd(&1) == inspect(T.KeptRefRearm)))
    assert {:ok, %{func: "handle_info"}} = Argus.InstrId.parse(site)
  end

  test "loops that stay one are quiet", %{rows: rows} do
    mods = rows |> Enum.map(&hd/1) |> MapSet.new()

    for quiet <- [
          T.InitOnly,
          T.CancelFirst,
          T.IdempotentLoop,
          T.RefTagged,
          T.ContinueArm,
          T.OtherProcess,
          T.OneShot,
          T.RetryLoop,
          T.AfterJoin,
          T.Redispatch,
          T.SameTagResend,
          T.CastFromInit,
          :timer_loop_resend,
          :timer_loop_domain_db
        ] do
      refute MapSet.member?(mods, inspect(quiet)), "#{inspect(quiet)} reported"
    end
  end

  test "the finding says which callback multiplies the loop" do
    assert {:ok, %{findings: findings}} =
             Memo.run_analyses([T.ReloadLoop], analyses: [:mailbox])

    assert [finding] =
             Enum.filter(findings, &(&1.title == "Periodic timer loop armed again while it runs"))

    assert finding.severity == :warning
    assert finding.detail =~ "handle_cast/2 arms :reload again"
    assert [%{label: "the loop re-arms here and keeps no ref"}] = finding.related
  end
end
