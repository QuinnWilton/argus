defmodule Argus.Analyses.MessageFlowTest do
  use ExUnit.Case

  alias Argus.Souffle.CLI

  defp skip_without_souffle do
    unless CLI.available?(), do: flunk("souffle not installed")
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
