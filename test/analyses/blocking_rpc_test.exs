defmodule Argus.Analyses.BlockingRpcTest do
  use ExUnit.Case, async: true
  @moduletag :souffle

  alias Argus.Analyses.Blocking
  alias Argus.Test.Batch
  alias Argus.Test.Memo
  alias Argus.Test.Rows

  # Every test reads its fixtures' rows from one solve of them all
  # (`Argus.Test.Batch`; ARGUS_VERIFY_BATCH=1 checks each slice against
  # a solve of its own).
  @batched [
    Argus.Test.Fixtures.RpcInInit,
    Argus.Test.Fixtures.GlobalLockInInit,
    Argus.Test.Fixtures.RpcCaller,
    Argus.Test.Fixtures.RpcInCallback,
    Argus.Test.Fixtures.RpcViaHelperCallback,
    Argus.Test.Fixtures.GlobalLockModule,
    Argus.Test.Fixtures.RpcCollectors,
    Argus.Test.Fixtures.RpcTimeoutParam,
    Argus.Test.Fixtures.RpcQuickTargets,
    Argus.Test.Fixtures.RpcSelfBounded,
    [Argus.Test.Fixtures.RpcClosures, Argus.Test.Fixtures.RpcClosures.Directory],
    Argus.Test.Fixtures.RpcViaHelperInInit
  ]

  setup_all do
    %{batch: Batch.solve(:blocking, [@batched])}
  end

  defp analyze(%{batch: batch}, modules) do
    assert {:ok, results} = Batch.analyze(batch, modules)
    results
  end

  defp waits(results, "global"),
    do:
      Rows.where(results, :blocking, "unbounded_wait",
        kind: "global",
        drop: [:kind, :peer, :permille]
      )

  defp waits(results, kind),
    do:
      Rows.where(results, :blocking, "unbounded_wait",
        kind: kind,
        drop: [:kind, :detail, :nodes, :peer, :permille]
      )

  describe "unbounded_wait: rpc" do
    test "flags :rpc.call without a timeout, not the timeout variant", ctx do
      results = analyze(ctx, [Argus.Test.Fixtures.RpcCaller])
      funcs = Enum.map(waits(results, "rpc"), fn [func, _site, _variant] -> func end)

      assert Enum.any?(funcs, &String.contains?(&1, "call_no_timeout"))
      refute Enum.any?(funcs, &String.contains?(&1, "call_with_timeout"))
    end
  end

  describe "unbounded_wait: rpc prose" do
    # A peer that goes away is noticed within net_ticktime (erpc monitors
    # it); forever is a connected peer whose callee never answers.
    @tag souffle: false
    test "says what waits forever, and what only waits for net_ticktime" do
      attrs =
        Blocking.finding(:unbounded_wait, [
          "M:f/1",
          "M:f/1#3",
          "rpc",
          "rpc",
          "",
          "",
          "",
          "0"
        ])

      assert attrs.detail =~ "stays connected but never answers"
      assert attrs.detail =~ "holds this process forever"
      assert attrs.detail =~ "net_ticktime"
      refute attrs.detail =~ "partitioned"
    end
  end

  describe "unbounded_wait: rpc help" do
    @describetag souffle: false

    defp help(variant) do
      [help] =
        Blocking.finding(:unbounded_wait, [
          "M:f/1",
          "M:f/1#3",
          "rpc",
          variant,
          "",
          "",
          "",
          "0"
        ]).help

      help
    end

    # Only :rpc.call answers a timeout with a value; following that advice
    # for :erpc.call matches a value that never arrives.
    test "says what each API does when its timeout runs out" do
      assert help("rpc") =~ "{:badrpc, :timeout}"
      assert help("block_call") =~ "{:badrpc, :timeout}"
      assert help("multicall") =~ "bad nodes"
      assert help("erpc") =~ "raises `{:erpc, :timeout}`"
      assert help("erpc_multicall") =~ "{:error, {:erpc, :timeout}}"
      assert help("yield") =~ ":rpc.nb_yield/2"
      assert help("nb_yield") =~ ":rpc.nb_yield/2"
      assert help("erpc_receive") =~ ":erpc.receive_response/2"

      for variant <- ~w(multicall erpc erpc_multicall yield nb_yield erpc_receive) do
        refute help(variant) =~ "badrpc", variant
      end
    end

    test "names every variant's function in the detail" do
      for {variant, api} <- [
            {"rpc", ":rpc.call"},
            {"block_call", ":rpc.block_call"},
            {"multicall", ":rpc.multicall"},
            {"yield", ":rpc.yield"},
            {"nb_yield", ":rpc.nb_yield"},
            {"erpc", ":erpc.call"},
            {"erpc_multicall", ":erpc.multicall"},
            {"erpc_receive", ":erpc.receive_response"}
          ] do
        attrs =
          Blocking.finding(:unbounded_wait, [
            "M:f/1",
            "M:f/1#3",
            "rpc",
            variant,
            "",
            "",
            "",
            "0"
          ])

        assert attrs.detail =~ "calls #{api} with", variant
      end
    end
  end

  describe "unbounded_wait: the waits beyond call and multicall" do
    test "block_call, yield and receive_response without a timeout are flagged", ctx do
      results = analyze(ctx, [Argus.Test.Fixtures.RpcCollectors])

      found =
        waits(results, "rpc") |> Enum.map(fn [func, _site, v] -> {func, v} end) |> Enum.sort()

      assert found == [
               {"Argus.Test.Fixtures.RpcCollectors:await/1", "erpc_receive"},
               {"Argus.Test.Fixtures.RpcCollectors:block/1", "block_call"},
               {"Argus.Test.Fixtures.RpcCollectors:collect/1", "yield"}
             ]
    end
  end

  describe "unbounded_wait: a timeout taken as a parameter" do
    test "is flagged when a caller passes :infinity, with that caller as a frame", ctx do
      modules = [Argus.Test.Fixtures.RpcTimeoutParam]
      results = analyze(ctx, modules)

      assert [["Argus.Test.Fixtures.RpcTimeoutParam:remote/5", "caller", ""]] =
               Rows.where(results, :blocking, "unbounded_wait",
                 kind: "rpc",
                 drop: [:kind, :site, :api, :peer, :permille]
               )

      assert [["Argus.Test.Fixtures.RpcTimeoutParam:remote/5", _site, caller]] =
               results["rpc_infinity_caller"]

      assert caller == "Argus.Test.Fixtures.RpcTimeoutParam:remote/4"

      {:ok, findings} = Argus.Findings.run(modules, analyses: [:blocking])
      [finding] = Enum.filter(findings.findings, &(&1.title == "RPC without a bounded timeout"))
      assert finding.detail =~ "a caller passes `:infinity` there"
      assert [%{label: "passes :infinity as the timeout"}] = finding.related
    end
  end

  describe "unbounded_wait: rpc to a function that answers at once" do
    test "is not flagged; the same call to one that can wait is", ctx do
      results = analyze(ctx, [Argus.Test.Fixtures.RpcQuickTargets])
      funcs = Enum.map(waits(results, "rpc"), fn [func, _site, _variant] -> func end)

      assert Enum.sort(funcs) == [
               "Argus.Test.Fixtures.RpcQuickTargets:lookup/2",
               "Argus.Test.Fixtures.RpcQuickTargets:scan/2"
             ]
    end
  end

  describe "unbounded_wait: rpc to a function that bounds its own wait" do
    test "which_applications/0 is not flagged; which_applications/1 is", ctx do
      results = analyze(ctx, [Argus.Test.Fixtures.RpcSelfBounded])
      funcs = Enum.map(waits(results, "rpc"), fn [func, _site, _variant] -> func end)

      assert funcs == ["Argus.Test.Fixtures.RpcSelfBounded:apps_within/2"]
    end
  end

  describe "unbounded_wait: rpc of a closure" do
    # A closure runs on the peer only where this version of its module is
    # loaded (badfun anywhere else): it is judged by its body.
    test "is flagged only when something it runs can wait", ctx do
      results =
        analyze(ctx, [Argus.Test.Fixtures.RpcClosures, Argus.Test.Fixtures.RpcClosures.Directory])

      funcs =
        results
        |> waits("rpc")
        |> Enum.map(fn [func, _site, _variant] -> func |> String.split(":") |> List.last() end)
        |> Enum.sort()

      assert funcs == ~w(await/1 handed/2 named/2 other_module/2 ping_forever/2)
    end

    # The effect model records `x.field`'s helper as a dot_dispatch
    # dynamic_call when it runs: the answer must not turn on that.
    test "is judged alike when every analysis's extractors run" do
      modules = [Argus.Test.Fixtures.RpcClosures, Argus.Test.Fixtures.RpcClosures.Directory]
      {:ok, results} = Memo.run_analyses(modules, analyses: :all)

      funcs =
        for %{analysis: :blocking, title: "RPC without a bounded timeout", mfa: {_, f, a}} <-
              results.findings,
            do: "#{f}/#{a}"

      assert Enum.sort(funcs) == ~w(await/1 handed/2 named/2 other_module/2 ping_forever/2)
    end
  end

  describe "a wait init/1 holds is startup's finding" do
    test "an rpc in init/1, and a :global lock init/1 reaches, are reported once, by startup",
         ctx do
      modules = [Argus.Test.Fixtures.RpcInInit, Argus.Test.Fixtures.GlobalLockInInit]
      results = analyze(ctx, modules)
      assert waits(results, "rpc") == []
      assert waits(results, "global") == []

      {:ok, startup} = Memo.analyze(modules, :startup)
      kinds = startup["blocks_on_peer"] |> Enum.map(&Enum.at(&1, 3)) |> Enum.sort()
      assert "global" in kinds and "remote" in kinds
    end
  end

  describe "a helper init/1 calls on its own stack" do
    test "is startup's finding, and an rpc init/1 does not reach stays here", ctx do
      modules = [Argus.Test.Fixtures.RpcViaHelperInInit]

      funcs =
        Enum.map(waits(analyze(ctx, modules), "rpc"), fn [func, _site, _variant] -> func end)

      assert funcs == ["Argus.Test.Fixtures.RpcViaHelperInInit:fetch_later/1"]

      {:ok, startup} = Memo.analyze(modules, :startup)
      assert [[_init, "init", _, "remote" | _]] = startup["blocks_on_peer"]
    end
  end

  describe "unbounded_wait: rpc_in_callback" do
    test "flags RPC directly inside handle_call", ctx do
      results = analyze(ctx, [Argus.Test.Fixtures.RpcInCallback])

      assert Enum.any?(waits(results, "rpc_in_callback"), fn [func, site, _variant] ->
               # Anchored at the rpc itself, not at the callback's head.
               String.contains?(func, "RpcInCallback:handle_call/3") and
                 site =~ "RpcInCallback:handle_call/3#"
             end)
    end

    test "does not flag RPC reached only transitively through a helper", ctx do
      # Deliberate direct-only scope: the transitive clause (call_reachable
      # through a guarded dispatcher) produced only false positives on the
      # corpus. The RPC itself is still reported by rpc_without_timeout.
      results = analyze(ctx, [Argus.Test.Fixtures.RpcViaHelperCallback])

      assert waits(results, "rpc_in_callback") == []

      assert Enum.any?(waits(results, "rpc"), fn [func, _site, _variant] ->
               String.contains?(func, "RpcViaHelperCallback")
             end)
    end
  end

  describe "unbounded_wait: global" do
    test "flags blocking lock acquisition, not zero-retry attempts", ctx do
      results = analyze(ctx, [Argus.Test.Fixtures.GlobalLockModule])

      funcs =
        Enum.map(waits(results, "global"), fn [func, _site, _op, _retries, _nodes] -> func end)

      assert Enum.any?(funcs, &String.contains?(&1, "lock_default"))
      assert Enum.any?(funcs, &String.contains?(&1, "lock_infinity"))
      refute Enum.any?(funcs, &String.contains?(&1, "try_lock_once"))
      refute Enum.any?(funcs, &String.contains?(&1, "del/"))
    end
  end
end
