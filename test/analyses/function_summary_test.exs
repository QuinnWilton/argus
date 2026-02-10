defmodule Argus.Analyses.FunctionSummaryTest do
  use ExUnit.Case

  alias Argus.Souffle.CLI

  defp skip_without_souffle do
    unless CLI.available?(), do: flunk("souffle not installed")
  end

  describe "function_summary.dl" do
    test "identifies function summaries for GenServer wrappers" do
      skip_without_souffle()

      assert {:ok, results} =
               Argus.analyze([Argus.Test.Fixtures.MyGenServer], :function_summary)

      assert Map.has_key?(results, "function_summary_call")

      summaries = results["function_summary_call"]
      assert length(summaries) > 0

      # get_value/1 delegates to GenServer.call.
      assert Enum.any?(summaries, fn [func, mod, _f, _a] ->
               String.contains?(func, "get_value") and mod == "GenServer"
             end)
    end

    test "detects tail-call delegates" do
      skip_without_souffle()

      assert {:ok, results} =
               Argus.analyze([Argus.Test.Fixtures.FunctionSummaryFixture], :function_summary)

      assert Map.has_key?(results, "tail_call_delegate")

      delegates = results["tail_call_delegate"]

      # get_value/1 is a tail-call delegate to GenServer.call.
      assert Enum.any?(delegates, fn [func, mod, _f, _a] ->
               String.contains?(func, "get_value") and mod == "GenServer"
             end)
    end

    test "computes function sizes" do
      skip_without_souffle()

      assert {:ok, results} =
               Argus.analyze([Argus.Test.Fixtures.FunctionSummaryFixture], :function_summary)

      assert Map.has_key?(results, "function_size")

      sizes = results["function_size"]
      assert length(sizes) > 0

      # All sizes should be positive.
      for [_func, size] <- sizes do
        assert String.to_integer(size) > 0
      end
    end

    test "identifies small functions" do
      skip_without_souffle()

      assert {:ok, results} =
               Argus.analyze([Argus.Test.Fixtures.FunctionSummaryFixture], :function_summary)

      assert Map.has_key?(results, "small_function")

      small = results["small_function"]
      assert length(small) > 0

      # get_value/1 should be small (just a GenServer.call wrapper).
      assert Enum.any?(small, fn [func] ->
               String.contains?(func, "get_value")
             end)
    end

    test "computes transitive summaries" do
      skip_without_souffle()

      assert {:ok, results} =
               Argus.analyze([Argus.Test.Fixtures.FunctionSummaryFixture], :function_summary)

      assert Map.has_key?(results, "transitive_summary")

      transitive = results["transitive_summary"]
      assert length(transitive) > 0
    end

    test "runs without error on stdlib module" do
      skip_without_souffle()

      assert {:ok, results} = Argus.analyze([:maps], :function_summary)
      assert is_map(results)
      assert Map.has_key?(results, "function_size")
    end
  end
end
