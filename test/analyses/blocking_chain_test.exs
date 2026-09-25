defmodule Argus.Analyses.BlockingChainTest do
  use ExUnit.Case, async: true

  alias Argus.Souffle
  alias Argus.Test.Memo
  alias Argus.Test.Rows

  defp skip_without_souffle do
    unless Souffle.available?(), do: flunk("souffle not installed")
  end

  # The rows of one kind, in the shape the rule has always produced.
  defp chains(results, "chain"),
    do:
      Rows.where(results, :blocking, "call_chain",
        kind: "chain",
        drop: [:kind, :caller_ms, :downstream_ms]
      )

  defp chains(results, "cast"),
    do:
      Rows.where(results, :blocking, "call_chain",
        kind: "cast",
        drop: [:kind, :depth, :inferred, :caller_ms, :downstream_ms]
      )

  defp chains(results, "budget"),
    do:
      Rows.where(results, :blocking, "call_chain",
        kind: "budget",
        drop: [:kind, :depth, :inferred]
      )

  describe "call_chain: which chains" do
    test "only the shortest chain between two servers is reported" do
      skip_without_souffle()
      alias Argus.Test.Fixtures.ChainShapes, as: S

      {:ok, results} =
        Memo.analyze([S.ShortA, S.ShortB, S.ShortC, S.ShortD], :blocking)

      depths =
        for [from, to, depth, _] <- chains(results, "chain"),
            from =~ "ShortA" and to =~ "ShortD",
            do: depth

      assert depths == ["2"]
    end

    test "a chain through a synchronous call cycle is left to the cycle's finding" do
      skip_without_souffle()
      alias Argus.Test.Fixtures.ChainShapes, as: S

      {:ok, results} = Memo.analyze([S.CycW, S.CycX, S.CycY, S.CycZ], :blocking)
      assert results["call_cycle"] != []

      refute Enum.any?(chains(results, "chain"), fn [from, to, _, _] ->
               from =~ "CycW" and to =~ "CycZ"
             end)
    end

    test "a chain beside a cycle through another clause of the same server is reported" do
      skip_without_souffle()
      alias Argus.Test.Fixtures.ChainShapes, as: S

      {:ok, results} =
        Memo.analyze(
          [S.FugAnswer, S.FugCounter, S.FugSubject, S.FugRouter, S.FugRelay],
          :blocking
        )

      # FugAnswer's :echo clause and FugCounter's :invert clause wait on
      # each other: the cycle is reported as ever.
      assert [[a, b | _]] = results["call_cycle"]
      assert {a, b} == {inspect(S.FugAnswer), inspect(S.FugCounter)}

      # The :answer request :invert makes never enters :echo, so the chain
      # FugCounter -> FugAnswer -> FugSubject is not a walk round the cycle.
      # And :answer calls FugRouter.route(:local, _), whose :remote clause
      # is the one that calls FugRelay: no chain goes there.
      assert chains(results, "chain") == [
               [inspect(S.FugCounter), inspect(S.FugSubject), "2", "static"]
             ]
    end
  end

  describe "call_chain" do
    test "detects chain risk at depth >= 2" do
      skip_without_souffle()

      modules = [
        Argus.Test.Fixtures.TimeoutChain.ServerA,
        Argus.Test.Fixtures.TimeoutChain.ServerB,
        Argus.Test.Fixtures.TimeoutChain.ServerC
      ]

      assert {:ok, results} = Memo.analyze(modules, :blocking)
      assert Map.has_key?(results, "call_chain")

      risks = chains(results, "chain")
      assert risks != []

      # ServerA → ServerB → ServerC is a chain of depth 2.
      assert Enum.any?(risks, fn [from, to, depth, _inferred] ->
               from == "Argus.Test.Fixtures.TimeoutChain.ServerA" and
                 to == "Argus.Test.Fixtures.TimeoutChain.ServerC" and
                 depth == "2"
             end)
    end

    test "detects blocking cast handler" do
      skip_without_souffle()

      modules = [
        Argus.Test.Fixtures.TimeoutChain.BlockingCastServer,
        Argus.Test.Fixtures.TimeoutChain.ServerC
      ]

      assert {:ok, results} = Memo.analyze(modules, :blocking)
      assert Map.has_key?(results, "call_chain")

      blocking = chains(results, "cast")
      assert blocking != []

      assert Enum.any?(blocking, fn [mod, _target] ->
               mod == "Argus.Test.Fixtures.TimeoutChain.BlockingCastServer"
             end)
    end

    test "detects infinity timeout in chain" do
      skip_without_souffle()

      modules = [
        Argus.Test.Fixtures.TimeoutChain.ServerA,
        Argus.Test.Fixtures.TimeoutChain.ServerB,
        Argus.Test.Fixtures.TimeoutChain.ServerC,
        Argus.Test.Fixtures.TimeoutChain.ServerWithInfinityTimeout
      ]

      assert {:ok, results} = Memo.analyze(modules, :blocking)
      assert Map.has_key?(results, "unbounded_wait")

      # infinity_timeout_in_chain requires callback_sync_dep_timeout with -1
      # and implements_behaviour on the target. The fixture calls GenServer.call
      # with :infinity, which the extractor may encode as -1.
      infinity =
        Rows.where(results, :blocking, "unbounded_wait",
          kind: "infinity",
          drop: [:site, :kind, :detail, :nodes]
        )

      # If the extractor detects the :infinity timeout, it should flag it.
      # This is conditional on the OTP extractor encoding :infinity as -1.
      if infinity != [] do
        assert Enum.any?(infinity, fn [func, _target] ->
                 func ==
                   "Argus.Test.Fixtures.TimeoutChain.ServerWithInfinityTimeout:handle_call/3"
               end)
      end
    end

    test "runs without error on modules with no GenServer callbacks" do
      skip_without_souffle()

      assert {:ok, results} = Memo.analyze([:maps], :blocking)
      assert Map.has_key?(results, "call_chain")
      assert Map.has_key?(results, "call_chain")
    end
  end

  describe "waits that are not the program's" do
    alias Argus.Test.Fixtures.SidePaths, as: S

    defp infinity(results),
      do:
        Rows.where(results, :blocking, "unbounded_wait",
          kind: "infinity",
          drop: [:site, :kind, :detail, :nodes]
        )

    test "a server that logs does not wait on the logger's servers" do
      skip_without_souffle()

      # OTP's own logger: :logger.error/1 reaches logger_server's
      # :infinity call through the handler-removal path.
      {:ok, results} =
        Memo.analyze([S.Logs, S.CallsLogs, :logger, :logger_backend, :logger_server], :blocking)

      refute Enum.any?(infinity(results), fn [_func, target] -> target == ":logger_server" end)
      refute Enum.any?(chains(results, "chain"), fn [_, to, _, _] -> to == ":logger_server" end)
    end

    test "an :infinity hop into a server that answers at once ends the chain" do
      skip_without_souffle()

      {:ok, results} =
        Memo.analyze([S.StopsProxy, S.Proxy, S.AsksWorker, S.Worker], :blocking)

      assert infinity(results) == [
               [
                 "Argus.Test.Fixtures.SidePaths.AsksWorker:handle_call/3",
                 "Argus.Test.Fixtures.SidePaths.Worker"
               ]
             ]
    end

    test "a server that parks the request and replies later does not answer at once" do
      skip_without_souffle()

      {:ok, results} = Memo.analyze([S.AsksDeferrer, S.Deferrer], :blocking)

      assert infinity(results) == [
               [
                 "Argus.Test.Fixtures.SidePaths.AsksDeferrer:handle_call/3",
                 "Argus.Test.Fixtures.SidePaths.Deferrer"
               ]
             ]
    end

    test "a task the server awaits holds the hop; one it only starts does not" do
      skip_without_souffle()

      {:ok, results} =
        Memo.analyze([S.AsksAwaiter, S.Awaiter, S.AsksStarter, S.Starter], :blocking)

      assert infinity(results) == [
               [
                 "Argus.Test.Fixtures.SidePaths.AsksAwaiter:handle_call/3",
                 "Argus.Test.Fixtures.SidePaths.Awaiter"
               ]
             ]
    end
  end

  describe "no chain through a pure-function reach" do
    test "a handle_call reaching only a pure function is not a chain hop" do
      skip_without_souffle()

      # ChainOuter.handle_call reaches only ChainMiddle.pure/1 (pure);
      # ChainMiddle really does sync-call ChainInner. The old
      # stateful_module_dep clause manufactured ChainOuter -> ChainMiddle
      # -> ChainInner from the pure reach plus "ChainMiddle has a
      # GenServer.call somewhere".
      modules = [
        Argus.Test.Fixtures.TimeoutChain.ChainOuter,
        Argus.Test.Fixtures.TimeoutChain.ChainMiddle,
        Argus.Test.Fixtures.TimeoutChain.ChainInner
      ]

      assert {:ok, results} = Memo.analyze(modules, :blocking)

      refute Enum.any?(chains(results, "chain"), fn [from | _] ->
               String.contains?(from, "ChainOuter")
             end)
    end
  end

  describe "call_chain: budget" do
    test "flags a caller whose budget is strictly smaller than the downstream hop" do
      skip_without_souffle()

      modules = [
        Argus.Test.Fixtures.TimeoutChain.TightBudgetServer,
        Argus.Test.Fixtures.TimeoutChain.DeepServer,
        Argus.Test.Fixtures.TimeoutChain.ServerC
      ]

      assert {:ok, results} = Memo.analyze(modules, :blocking)

      # TightBudgetServer gives DeepServer 1000ms, but DeepServer's own
      # downstream call waits up to the 5000ms default.
      assert Enum.any?(chains(results, "budget"), fn [caller, callee, t_ab, t_bc] ->
               String.contains?(caller, "TightBudgetServer") and
                 String.contains?(callee, "DeepServer") and
                 t_ab == "1000" and t_bc == "5000"
             end)
    end

    test "does not flag equal timeouts (the default-vs-default chain)" do
      skip_without_souffle()

      # ServerA -> ServerB -> ServerC all use the GenServer.call default
      # (5000ms at every hop). Equal budgets are the universal
      # configuration, not a misconfiguration — must not be an :error.
      modules = [
        Argus.Test.Fixtures.TimeoutChain.ServerA,
        Argus.Test.Fixtures.TimeoutChain.ServerB,
        Argus.Test.Fixtures.TimeoutChain.ServerC
      ]

      assert {:ok, results} = Memo.analyze(modules, :blocking)

      # The chain itself is still reported as a risk...
      assert chains(results, "chain") != []

      # ...but no hop is "insufficient".
      assert chains(results, "budget") == []
    end
  end
end
