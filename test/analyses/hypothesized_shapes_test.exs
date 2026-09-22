defmodule Argus.Analyses.HypothesizedShapesTest do
  use ExUnit.Case, async: false

  alias Argus.Test.Fixtures.Hypothesized, as: H
  alias Argus.Test.Rows

  defp skip_without_souffle do
    unless Argus.Souffle.available?(), do: flunk("souffle not installed")
  end

  defp rows(results, relation, column \\ 0),
    do:
      results
      |> Map.get(relation, [])
      |> Enum.map(&Enum.at(&1, column))
      |> Enum.uniq()
      |> Enum.sort()

  test "an rpc result matched without a badrpc clause, or used as a boolean, is reported" do
    skip_without_souffle()

    {:ok, r} =
      Argus.analyze(
        [
          H.RpcCaseNoBadrpc,
          H.RpcCaseWithBadrpc,
          H.RpcBoolean,
          H.ErpcBooleanNoRescue,
          H.ErpcBooleanRescued
        ],
        :failure
      )

    reported =
      r
      |> Map.get("unhandled_failure", [])
      |> Enum.reject(&(Enum.at(&1, 2) in ["rescue", "erpc_transport"]))
      |> Enum.map(&{hd(&1), Enum.at(&1, 3)})

    assert Enum.sort(reported) == [
             {"Argus.Test.Fixtures.Hypothesized.ErpcBooleanNoRescue:alive?/1", "boolean"},
             {"Argus.Test.Fixtures.Hypothesized.RpcBoolean:alive?/1", "boolean"},
             {"Argus.Test.Fixtures.Hypothesized.RpcCaseNoBadrpc:status/1", "case"}
           ]
  end

  test "a timer cancelled and re-armed with a bare message, without a flush, is reported" do
    skip_without_souffle()

    {:ok, r} =
      Argus.analyze(
        [
          H.TimerCancelNoFlush,
          H.TimerCancelWithFlush,
          H.TimerCancelBlockingFlush,
          H.TimerCancelWrongFlush,
          H.TimerWithRef,
          H.TimerForwarded,
          H.TimerHelper,
          H.TimerForOther,
          H.TwoTimers,
          H.TwoTimersViaHelper
        ],
        :mailbox
      )

    rows = Map.get(r, "timer_cancel_without_flush", [])

    # Both the cancel and the arm are instructions a frame can point at.
    for [_mod, _cancel, _arm, _key, _message, cancel_site, arm_site] <- rows do
      assert {:ok, _} = Argus.InstrId.parse(cancel_site)
      assert {:ok, _} = Argus.InstrId.parse(arm_site)
    end

    reported =
      rows
      |> Enum.map(&{hd(&1), Enum.at(&1, 3), Enum.at(&1, 4)})
      |> Enum.sort()

    assert reported == [
             {"Argus.Test.Fixtures.Hypothesized.TimerCancelNoFlush", ":timer", ":tick"},
             {"Argus.Test.Fixtures.Hypothesized.TimerCancelWrongFlush", ":timer", ":tick"},
             {"Argus.Test.Fixtures.Hypothesized.TimerForwarded", ":timer", ":heartbeat"},
             {"Argus.Test.Fixtures.Hypothesized.TimerHelper", ":tick_ref", ":tick"},
             {"Argus.Test.Fixtures.Hypothesized.TwoTimersViaHelper", ":cleanup_ref", ":cleanup"},
             {"Argus.Test.Fixtures.Hypothesized.TwoTimersViaHelper", ":heartbeat_ref",
              ":heartbeat"}
           ]
  end

  test "an async_nolink task whose messages have no clause is reported, once per missing shape" do
    skip_without_souffle()

    {:ok, r} =
      Argus.analyze([H.NolinkPartialInfo, H.NolinkBothClauses, H.NolinkCollected], :mailbox)

    nolink = Rows.where(r, :mailbox, "partial_handler", source: "task_nolink")

    assert nolink |> Enum.map(&hd/1) |> Enum.uniq() ==
             ["Argus.Test.Fixtures.Hypothesized.NolinkPartialInfo"]

    assert nolink |> Enum.map(&Enum.at(&1, 3)) |> Enum.sort() == ["down", "reply"]
  end

  test "a connect in init/1 with no reconnect path is reported" do
    skip_without_souffle()

    {:ok, r} =
      Argus.analyze(
        [H.ConnectInInit, H.ConnectWithBackoff, H.ConnectWithGenericBackoff],
        :startup
      )

    assert r
           |> Rows.where(:startup, "unbounded_effect_in_init", kind: "connect")
           |> Enum.map(&hd/1)
           |> Enum.uniq() == ["Argus.Test.Fixtures.Hypothesized.ConnectInInit"]
  end

  test "a handler stopping a sibling through its API is reported; asking the supervisor is not" do
    skip_without_souffle()

    {:ok, r} =
      Argus.analyze(
        [
          H.SiblingStop.Sup,
          H.SiblingStop.Workers,
          H.SiblingStop.Coordinator,
          H.SiblingStop.PoliteCoordinator
        ],
        :shutdown
      )

    stops =
      r
      |> Rows.where(:shutdown, "teardown_touches_sibling", phase: "handler")
      |> Enum.map(&hd/1)
      |> Enum.uniq()

    assert stops == ["Argus.Test.Fixtures.Hypothesized.SiblingStop.Coordinator"]
  end

  test "a sibling pid cached in init/1 is reported under one_for_one, not under rest_for_one" do
    skip_without_souffle()

    {:ok, r} =
      Argus.analyze(
        [
          H.CachedPid.Sup,
          H.CachedPid.RestSup,
          H.CachedPid.Store,
          H.CachedPid.Client,
          H.CachedPid.OrderedClient
        ],
        :coupling
      )

    cached =
      r
      |> Map.get("sibling_dependency", [])
      |> Enum.filter(&(Enum.at(&1, 3) == "cached_pid"))
      |> Enum.map(&Enum.at(&1, 1))

    assert cached == ["Argus.Test.Fixtures.Hypothesized.CachedPid.Client"]
  end
end
