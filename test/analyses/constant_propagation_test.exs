defmodule Argus.Analyses.ConstantPropagationTest do
  use ExUnit.Case

  alias Argus.Souffle.CLI

  defp skip_without_souffle do
    unless CLI.available?(), do: flunk("souffle not installed")
  end

  describe "constant_propagation.dl" do
    test "computes constant_def from literal values" do
      skip_without_souffle()

      assert {:ok, results} =
               Argus.analyze(
                 [Argus.Test.Fixtures.ConstantPropagationFixture],
                 :constant_propagation
               )

      assert Map.has_key?(results, "constant_def")
      constants = results["constant_def"]
      assert length(constants) > 0
    end

    test "propagates values through moves" do
      skip_without_souffle()

      assert {:ok, results} =
               Argus.analyze(
                 [Argus.Test.Fixtures.ConstantPropagationFixture],
                 :constant_propagation
               )

      assert Map.has_key?(results, "value_at")
      values = results["value_at"]
      assert length(values) > 0
    end

    test "computes unique_value_at" do
      skip_without_souffle()

      assert {:ok, results} =
               Argus.analyze(
                 [Argus.Test.Fixtures.ConstantPropagationFixture],
                 :constant_propagation
               )

      assert Map.has_key?(results, "unique_value_at")
      # The linear chain should produce unique values.
      unique = results["unique_value_at"]
      assert length(unique) > 0
    end

    test "resolves call targets" do
      skip_without_souffle()

      assert {:ok, results} = Argus.analyze([:maps], :constant_propagation)
      assert Map.has_key?(results, "resolved_call_target")

      # :maps has remote calls with known modules.
      resolved = results["resolved_call_target"]
      assert length(resolved) > 0
    end

    test "runs without error on stdlib module" do
      skip_without_souffle()

      assert {:ok, results} = Argus.analyze([:maps], :constant_propagation)
      assert is_map(results)
      assert Map.has_key?(results, "value_at")
      assert Map.has_key?(results, "constant_def")
    end
  end
end
