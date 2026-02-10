defmodule Argus.Analyses.LoopsTest do
  use ExUnit.Case

  alias Argus.Souffle.CLI

  defp skip_without_souffle do
    unless CLI.available?(), do: flunk("souffle not installed")
  end

  describe "loops.dl" do
    test "detects back edges" do
      skip_without_souffle()

      assert {:ok, results} = Argus.analyze([:gen], :loops)
      assert Map.has_key?(results, "back_edge")

      edges = results["back_edge"]
      assert length(edges) > 0

      # Each entry should be [source, target, func].
      for [source, target, func] <- edges do
        assert is_binary(source)
        assert is_binary(target)
        assert is_binary(func)
      end
    end

    test "identifies loop heads" do
      skip_without_souffle()

      assert {:ok, results} = Argus.analyze([:gen], :loops)
      assert Map.has_key?(results, "loop_head")
      assert length(results["loop_head"]) > 0
    end

    test "computes loop membership" do
      skip_without_souffle()

      assert {:ok, results} = Argus.analyze([:gen], :loops)
      assert Map.has_key?(results, "in_loop")
      assert length(results["in_loop"]) > 0
    end

    test "detects receive loops" do
      skip_without_souffle()

      # :gen has receive instructions in loops.
      assert {:ok, results} = Argus.analyze([:gen], :loops)
      assert Map.has_key?(results, "receive_loop")
      assert length(results["receive_loop"]) > 0
    end

    test "computes loop sizes" do
      skip_without_souffle()

      assert {:ok, results} = Argus.analyze([:gen], :loops)
      assert Map.has_key?(results, "loop_size")

      sizes = results["loop_size"]
      assert length(sizes) > 0

      # All loop sizes should be positive.
      for [_head, _func, size] <- sizes do
        assert String.to_integer(size) > 0
      end
    end

    test "detects loop exits" do
      skip_without_souffle()

      assert {:ok, results} = Argus.analyze([:gen], :loops)
      assert Map.has_key?(results, "loop_exit")
      # :gen loops should have exits.
      assert length(results["loop_exit"]) > 0
    end

    test "detects loops in fixture" do
      skip_without_souffle()

      assert {:ok, results} =
               Argus.analyze([Argus.Test.Fixtures.LoopsFixture], :loops)

      assert Map.has_key?(results, "loop_head")
      # The fixture has recursive functions that create loops.
      assert length(results["back_edge"]) > 0
    end

    test "runs without error on stdlib module" do
      skip_without_souffle()

      assert {:ok, results} = Argus.analyze([:maps], :loops)
      assert is_map(results)
      assert Map.has_key?(results, "back_edge")
      assert Map.has_key?(results, "loop_head")
    end
  end
end
