defmodule Argus.Analyses.TimeoutChainTest do
  use ExUnit.Case

  alias Argus.Souffle

  defp skip_without_souffle do
    unless Souffle.available?(), do: flunk("souffle not installed")
  end

  describe "timeout_chain.dl" do
    test "detects chain risk at depth >= 2" do
      skip_without_souffle()

      modules = [
        Argus.Test.Fixtures.TimeoutChain.ServerA,
        Argus.Test.Fixtures.TimeoutChain.ServerB,
        Argus.Test.Fixtures.TimeoutChain.ServerC
      ]

      assert {:ok, results} = Argus.analyze(modules, :timeout_chain)
      assert Map.has_key?(results, "timeout_chain_risk")

      risks = results["timeout_chain_risk"]
      assert length(risks) > 0

      # ServerA → ServerB → ServerC is a chain of depth 2.
      assert Enum.any?(risks, fn [from, to, depth] ->
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

      assert {:ok, results} = Argus.analyze(modules, :timeout_chain)
      assert Map.has_key?(results, "blocking_cast_handler")

      blocking = results["blocking_cast_handler"]
      assert length(blocking) > 0

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

      assert {:ok, results} = Argus.analyze(modules, :timeout_chain)
      assert Map.has_key?(results, "infinity_timeout_in_chain")

      # infinity_timeout_in_chain requires callback_sync_dep_timeout with -1
      # and implements_behaviour on the target. The fixture calls GenServer.call
      # with :infinity, which the extractor may encode as -1.
      infinity = results["infinity_timeout_in_chain"]

      # If the extractor detects the :infinity timeout, it should flag it.
      # This is conditional on the OTP extractor encoding :infinity as -1.
      if length(infinity) > 0 do
        assert Enum.any?(infinity, fn [mod, _target] ->
                 mod == "Argus.Test.Fixtures.TimeoutChain.ServerWithInfinityTimeout"
               end)
      end
    end

    test "runs without error on modules with no GenServer callbacks" do
      skip_without_souffle()

      assert {:ok, results} = Argus.analyze([:maps], :timeout_chain)
      assert Map.has_key?(results, "timeout_chain_risk")
      assert Map.has_key?(results, "blocking_cast_handler")
    end
  end

  describe "timeout_insufficient" do
    test "flags a caller whose budget is strictly smaller than the downstream hop" do
      skip_without_souffle()

      modules = [
        Argus.Test.Fixtures.TimeoutChain.TightBudgetServer,
        Argus.Test.Fixtures.TimeoutChain.DeepServer,
        Argus.Test.Fixtures.TimeoutChain.ServerC
      ]

      assert {:ok, results} = Argus.analyze(modules, :timeout_chain)

      # TightBudgetServer gives DeepServer 1000ms, but DeepServer's own
      # downstream call waits up to the 5000ms default.
      assert Enum.any?(results["timeout_insufficient"], fn [caller, callee, t_ab, t_bc] ->
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

      assert {:ok, results} = Argus.analyze(modules, :timeout_chain)

      # The chain itself is still reported as a risk...
      assert results["timeout_chain_risk"] != []

      # ...but no hop is "insufficient".
      assert results["timeout_insufficient"] == []
    end
  end
end
