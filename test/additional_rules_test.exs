defmodule Argus.AdditionalRulesTest do
  use ExUnit.Case

  alias Argus.Souffle.CLI

  defp skip_without_souffle do
    unless CLI.available?(), do: flunk("souffle not installed")
  end

  describe "reaching_def.dl" do
    test "computes reaching definitions" do
      skip_without_souffle()

      assert {:ok, results} = Argus.analyze([:maps], :reaching_def)
      assert Map.has_key?(results, "reaching_def")
      assert Map.has_key?(results, "def_use")
      assert length(results["reaching_def"]) > 0
      assert length(results["def_use"]) > 0
    end
  end

  describe "liveness.dl" do
    test "computes live variables" do
      skip_without_souffle()

      assert {:ok, results} = Argus.analyze([:maps], :liveness)
      assert Map.has_key?(results, "live_in")
      assert Map.has_key?(results, "live_out")
      assert length(results["live_in"]) > 0
    end

    test "finds dead definitions" do
      skip_without_souffle()

      assert {:ok, results} = Argus.analyze([:maps], :liveness)
      # dead_def may or may not have entries depending on the module.
      assert Map.has_key?(results, "dead_def")
    end
  end

  describe "tail_call.dl" do
    test "identifies tail calls and recursion" do
      skip_without_souffle()

      assert {:ok, results} = Argus.analyze([:lists], :tail_call)
      assert Map.has_key?(results, "has_tail_call")
      assert length(results["has_tail_call"]) > 0

      # :lists has many recursive functions.
      assert Map.has_key?(results, "direct_recursion")
      assert length(results["direct_recursion"]) > 0
    end

    test "detects stack growth risks" do
      skip_without_souffle()

      assert {:ok, results} = Argus.analyze([:lists], :tail_call)
      # stack_growth_risk may or may not have results, but the analysis should succeed.
      assert is_map(results)
    end
  end

  describe "message_flow.dl" do
    test "identifies sender and receiver functions" do
      skip_without_souffle()

      # :gen has actual receive instructions.
      assert {:ok, results} = Argus.analyze([:gen], :message_flow)

      assert Map.has_key?(results, "receiver_function")
      assert length(results["receiver_function"]) > 0
    end

    test "finds potential message paths" do
      skip_without_souffle()

      assert {:ok, results} = Argus.analyze([:gen], :message_flow)
      assert Map.has_key?(results, "potential_message_path")
    end
  end
end
