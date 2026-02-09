defmodule Mix.Tasks.ArgusTest do
  use ExUnit.Case

  alias Argus.Souffle.CLI

  defp skip_without_souffle do
    unless CLI.available?(), do: flunk("souffle not installed")
  end

  describe "run/1" do
    test "raises without arguments" do
      assert_raise Mix.Error, ~r/Usage/, fn ->
        Mix.Tasks.Argus.run([])
      end
    end

    test "raises for unknown analysis" do
      skip_without_souffle()

      assert_raise Mix.Error, ~r/Unknown analysis/, fn ->
        Mix.Tasks.Argus.run(["nonexistent"])
      end
    end

    test "runs cfg analysis with --modules" do
      skip_without_souffle()

      # Capture output — this should succeed without raising.
      Mix.Tasks.Argus.run(["cfg", "--modules", ":lists"])
    end

    test "runs callgraph analysis" do
      skip_without_souffle()

      Mix.Tasks.Argus.run(["callgraph", "--modules", "Enum"])
    end

    test "parses Erlang module names" do
      skip_without_souffle()

      Mix.Tasks.Argus.run(["cfg", "--modules", ":maps"])
    end
  end
end
