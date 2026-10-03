defmodule Argus.Analyses.HypothesizedShapesTest do
  use ExUnit.Case, async: true
  @moduletag :souffle

  alias Argus.Test.Fixtures.Hypothesized, as: H
  alias Argus.Test.Memo
  alias Argus.Test.Rows

  test "an rpc result matched without a badrpc clause, or used as a boolean, is reported" do
    {:ok, r} =
      Memo.analyze(
        [
          H.RpcCaseNoBadrpc,
          H.RpcCaseWithBadrpc,
          H.RpcBoolean,
          H.BlockCallCaseNoBadrpc,
          H.YieldBoolean,
          H.NbYieldCase,
          H.ErpcBooleanNoRescue,
          H.ErpcBooleanRescued,
          H.ErpcBooleanUnrelatedRescue,
          H.ErpcBooleanCatchesExit,
          H.ErpcBooleanCallerRescues
        ],
        :failure
      )

    reported =
      r
      |> Map.get("unhandled_failure", [])
      |> Enum.reject(&(Enum.at(&1, 2) in ["rescue", "erpc_transport"]))
      |> Enum.map(&{hd(&1), Enum.at(&1, 3)})

    assert Enum.sort(reported) == [
             {"Argus.Test.Fixtures.Hypothesized.BlockCallCaseNoBadrpc:status/1", "case"},
             {"Argus.Test.Fixtures.Hypothesized.ErpcBooleanCatchesExit:status/1", "boolean"},
             {"Argus.Test.Fixtures.Hypothesized.ErpcBooleanNoRescue:alive?/1", "boolean"},
             {"Argus.Test.Fixtures.Hypothesized.ErpcBooleanUnrelatedRescue:status/2", "boolean"},
             {"Argus.Test.Fixtures.Hypothesized.RpcBoolean:alive?/1", "boolean"},
             {"Argus.Test.Fixtures.Hypothesized.RpcCaseNoBadrpc:status/1", "case"},
             {"Argus.Test.Fixtures.Hypothesized.YieldBoolean:alive?/1", "boolean"}
           ]
  end

  test "an rpc result a wrapper returns is judged where its caller matches it" do
    {:ok, r} =
      Memo.analyze(
        [H.RpcProto, H.RpcFacade, H.RpcWrapperCaller, H.RpcWrapperCallerHandled],
        :failure
      )

    reported =
      r
      |> Map.get("unhandled_failure", [])
      |> Enum.map(fn [func, _site, variant, shape, _] -> {func, variant, shape} end)
      |> Enum.sort()

    # Reported at the caller's call, not at the rpc the wrapper returns.
    assert reported == [
             {"Argus.Test.Fixtures.Hypothesized.RpcWrapperCaller:delete/2", "rpc", "case"},
             {"Argus.Test.Fixtures.Hypothesized.RpcWrapperCaller:status/2", "rpc", "case"}
           ]

    assert [[_func, _site, rpc_site, _wrapper]] =
             Enum.filter(r["rpc_wrapped"], fn [func | _] ->
               func =~ "RpcWrapperCaller:delete/2"
             end)

    assert rpc_site =~ "RpcProto:delete/2"

    [row] =
      Enum.filter(r["unhandled_failure"], fn [func | _] -> func =~ "RpcWrapperCaller:delete/2" end)

    finding = Argus.Analyses.Failure.finding(:unhandled_failure, row)
    assert finding.detail =~ "RpcFacade.delete/2, which returns :rpc.call's answer,"
  end

  test "a timer cancelled and re-armed with a bare message, without a flush, is reported" do
    {:ok, r} =
      Memo.analyze(
        [
          H.TimerCancelNoFlush,
          H.TimerCancelWithFlush,
          H.TimerCancelBlockingFlush,
          H.TimerCancelWrongFlush,
          H.TimerFlushedElsewhere,
          H.TimerFlushInHelper,
          H.TimerCancelHelperFlushInCaller,
          H.TimerFlushBeforeCancel,
          H.TimerFlushInOtherClause,
          H.TimerFlushHelperBeforeCancel,
          H.TimerCancelHelperFlushBeforeCall,
          H.TimerWithRef,
          H.TimerForwarded,
          H.TimerHelper,
          H.TimerForOther,
          H.TwoTimers,
          H.TwoTimersViaHelper,
          H.TimerCancelInOwnClause,
          H.TimerCancelInTerminate
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
             {"Argus.Test.Fixtures.Hypothesized.TimerCancelHelperFlushBeforeCall", ":timer",
              ":tick"},
             {"Argus.Test.Fixtures.Hypothesized.TimerCancelNoFlush", ":timer", ":tick"},
             {"Argus.Test.Fixtures.Hypothesized.TimerCancelWrongFlush", ":timer", ":tick"},
             {"Argus.Test.Fixtures.Hypothesized.TimerFlushBeforeCancel", ":timer", ":tick"},
             {"Argus.Test.Fixtures.Hypothesized.TimerFlushHelperBeforeCancel", ":timer", ":tick"},
             {"Argus.Test.Fixtures.Hypothesized.TimerFlushInOtherClause", ":timer", ":tick"},
             {"Argus.Test.Fixtures.Hypothesized.TimerFlushedElsewhere", ":timer", ":heartbeat"},
             {"Argus.Test.Fixtures.Hypothesized.TimerForwarded", ":timer", ":heartbeat"},
             {"Argus.Test.Fixtures.Hypothesized.TimerHelper", ":tick_ref", ":tick"},
             {"Argus.Test.Fixtures.Hypothesized.TwoTimersViaHelper", ":cleanup_ref", ":cleanup"},
             {"Argus.Test.Fixtures.Hypothesized.TwoTimersViaHelper", ":heartbeat_ref",
              ":heartbeat"}
           ]
  end

  test "a helper that cancels the field it reads with maps:get/3: the caller's flush is its" do
    {:ok, r} = Memo.analyze([:timer_flush_maps_get, :timer_loop_domain_db], :mailbox)

    reported =
      r
      |> Map.get("timer_cancel_without_flush", [])
      |> Enum.map(fn [mod, _cancel, _arm, key, message | _] -> {mod, key, message} end)
      |> Enum.uniq()

    # MongooseIM's service_domain_db flushes beside the call to its
    # cancelling helper; the other has no flush.
    assert reported == [{":timer_flush_maps_get", ":tref", ":check"}]
  end

  test "a cancel in the clause of the timer's own message is not the finding; another cancel is" do
    {:ok, r} = Memo.analyze([H.TimerCancelOwnClauseAndDown], :mailbox)

    sites =
      r
      |> Map.get("timer_cancel_without_flush", [])
      |> Enum.map(fn [_, _, _, _, ":check", cancel_site, _] -> cancel_site end)
      |> Enum.uniq()

    assert [site] = sites
    {:ok, %{func: "handle_info"} = id} = Argus.InstrId.parse(site)

    {:ok, facts} =
      Argus.Pipeline.extract([H.TimerCancelOwnClauseAndDown],
        extractors: [Argus.Extractors.ErrorHandling]
      )

    assert [[own, _, ":check"]] = facts[:cancel_clause]
    refute own == Argus.InstrId.format(id)
  end

  describe "where a key's finding points" do
    @buffer [H.WriteBuffer, H.WriteBufferIngest, H.WriteBufferTestSupport]

    defp timer_finding(modules) do
      assert {:ok, %{findings: findings}} = Memo.run_analyses(modules, analyses: [:mailbox])

      assert [finding] =
               Enum.filter(
                 findings,
                 &(&1.title == "Timer cancelled without flushing its message")
               )

      finding
    end

    test "at the cancel the program runs, not the one only its tests request" do
      # Plausible's WriteBuffer: handle_call(:flush) sorts first by name,
      # but only the test support requests :flush; the buffer-full branch
      # of handle_cast is the path inserts take.
      finding = timer_finding(@buffer)
      assert %Argus.InstrId{func: "handle_cast"} = finding.instr

      assert [%{label: "armed with :tick here", instr: %{func: "handle_cast"}}, also] =
               finding.related

      assert also.label == "also cancelled here, on a path only the tests take"
      assert %Argus.InstrId{func: "handle_call"} = also.instr
    end

    test "a flush/1 nothing calls is a public API, and ranks with the rest" do
      # Without the test support, nothing tells the two cancels apart:
      # the least row, as before.
      finding = timer_finding([H.WriteBuffer, H.WriteBufferIngest])
      assert %Argus.InstrId{func: "handle_call"} = finding.instr
      refute Enum.any?(finding.related, &(&1.label =~ "only the tests"))
    end

    test "a key whose only cancel is under test is still reported, there" do
      finding = timer_finding([H.FlushOnlyBuffer, H.FlushOnlyBufferTestSupport])
      assert %Argus.InstrId{func: "handle_call"} = finding.instr
      refute Enum.any?(finding.related, &(&1.label =~ "only the tests"))
    end
  end

  test "a timer armed and cancelled within one call, from a local ref, is reported" do
    {:ok, r} =
      Memo.analyze(
        [H.TimerLocalNoFlush, H.TimerLocalFlushed, H.TimerLocalStartTimer, H.TimerLocalEitherArm],
        :mailbox
      )

    assert [[mod, cancel, arm, "", ":deadline", cancel_site, arm_site]] =
             Map.get(r, "timer_cancel_without_flush", [])

    assert mod == "Argus.Test.Fixtures.Hypothesized.TimerLocalNoFlush"
    assert cancel == arm
    assert cancel =~ "handle_call/3"
    assert {:ok, _} = Argus.InstrId.parse(cancel_site)
    assert {:ok, _} = Argus.InstrId.parse(arm_site)
  end

  @tag souffle: false
  test "a local timer's finding says the stale message outlives the call" do
    row = [
      "M",
      "M:handle_call/3",
      "M:handle_call/3",
      "",
      ":deadline",
      "M:handle_call/3#20",
      "M:handle_call/3#9"
    ]

    f = Argus.Analyses.Mailbox.finding(:timer_cancel_without_flush, row)

    assert f.detail =~ "cancels it before returning"
    assert f.instr.idx == 20
    assert [%{label: "armed with :deadline here"}] = f.related
  end

  test "an async_nolink task whose messages have no clause is reported, once per missing shape" do
    {:ok, r} =
      Memo.analyze(
        [H.NolinkPartialInfo, H.NolinkBothClauses, H.NolinkCollected],
        :mailbox
      )

    nolink = Rows.where(r, :mailbox, "unhandled_info", source: "task")

    assert nolink |> Enum.map(&Enum.at(&1, 5)) |> Enum.uniq() ==
             ["Argus.Test.Fixtures.Hypothesized.NolinkPartialInfo"]

    assert nolink |> Enum.map(&Enum.at(&1, 3)) |> Enum.sort() == ["{:DOWN, …}", "{ref, …}"]
  end

  test "a connect in init/1 with no reconnect path is reported" do
    {:ok, r} =
      Memo.analyze(
        [H.ConnectInInit, H.ConnectWithBackoff, H.ConnectWithGenericBackoff],
        :startup
      )

    assert r
           |> Rows.where(:startup, "unbounded_effect_in_init",
             kind: "connect",
             drop: [:peer, :permille]
           )
           |> Enum.map(&hd/1)
           |> Enum.uniq() == ["Argus.Test.Fixtures.Hypothesized.ConnectInInit"]
  end

  test "a handler stopping a sibling through its API is reported; asking the supervisor is not" do
    {:ok, r} =
      Memo.analyze(
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

  test "a sibling pid cached in init/1 and called is reported under one_for_one only" do
    {:ok, r} =
      Memo.analyze(
        [
          H.CachedPid.Sup,
          H.CachedPid.RestSup,
          H.CachedPid.Store,
          H.CachedPid.Client,
          H.CachedPid.OrderedClient,
          H.CachedPid.RelaySup,
          H.CachedPid.Relay
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
