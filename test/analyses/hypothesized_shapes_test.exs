defmodule Argus.Analyses.HypothesizedShapesTest do
  use ExUnit.Case, async: false

  alias Argus.Test.Fixtures.Hypothesized, as: H

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
        :distributed
      )

    reported = r |> Map.get("rpc_result_unhandled", []) |> Enum.map(&{hd(&1), Enum.at(&1, 3)})

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
          H.TimerWithRef,
          H.TimerForwarded,
          H.TimerHelper,
          H.TimerForOther
        ],
        :error_handling
      )

    assert rows(r, "timer_cancel_without_flush") == [
             "Argus.Test.Fixtures.Hypothesized.TimerCancelNoFlush",
             "Argus.Test.Fixtures.Hypothesized.TimerForwarded",
             "Argus.Test.Fixtures.Hypothesized.TimerHelper"
           ]
  end

  test "an async_nolink task whose messages have no clause is reported, once per missing shape" do
    skip_without_souffle()

    {:ok, r} =
      Argus.analyze([H.NolinkPartialInfo, H.NolinkBothClauses, H.NolinkCollected], :unsafe_task)

    assert rows(r, "nolink_messages_unhandled") ==
             ["Argus.Test.Fixtures.Hypothesized.NolinkPartialInfo"]

    assert rows(r, "nolink_messages_unhandled", 3) == ["down", "reply"]
  end

  test "a connect in init/1 with no reconnect path is reported" do
    skip_without_souffle()

    {:ok, r} =
      Argus.analyze(
        [H.ConnectInInit, H.ConnectWithBackoff, H.ConnectWithGenericBackoff],
        :sync_call_in_init
      )

    assert rows(r, "connect_in_init_without_backoff") ==
             ["Argus.Test.Fixtures.Hypothesized.ConnectInInit"]
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
        :shutdown_safety
      )

    assert rows(r, "callback_stops_sibling") ==
             ["Argus.Test.Fixtures.Hypothesized.SiblingStop.Coordinator"]
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
        :supervision
      )

    assert rows(r, "cached_sibling_pid") == ["Argus.Test.Fixtures.Hypothesized.CachedPid.Client"]
  end
end
