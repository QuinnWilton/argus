defmodule Argus.Analyses.OneForOneCouplingTest do
  use ExUnit.Case

  alias Argus.Souffle.CLI

  defp skip_without_souffle do
    unless CLI.available?(), do: flunk("souffle not installed")
  end

  describe "one_for_one_coupling.dl" do
    test "analyzes coupling under one_for_one supervisors" do
      skip_without_souffle()

      modules = [
        Argus.Test.Fixtures.GoodSupervisor,
        Argus.Test.Fixtures.WorkerA,
        Argus.Test.Fixtures.WorkerB
      ]

      assert {:ok, results} = Argus.analyze(modules, :one_for_one_coupling)

      assert Map.has_key?(results, "one_for_one_coupling")
      assert Map.has_key?(results, "wrong_start_order")
    end

    test "wrong_start_order ignores runtime-only call paths" do
      skip_without_souffle()

      modules = [
        Argus.Test.Fixtures.RuntimeCallSupervisor,
        Argus.Test.Fixtures.RuntimeCallerWorker,
        Argus.Test.Fixtures.WorkerA
      ]

      assert {:ok, results} = Argus.analyze(modules, :one_for_one_coupling)

      # RuntimeCallerWorker calls WorkerA only from handle_call, not init.
      # wrong_start_order should be empty.
      assert results["wrong_start_order"] == []
    end
  end
end
