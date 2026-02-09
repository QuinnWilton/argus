defmodule Mix.Tasks.ArgusTest do
  use ExUnit.Case

  import ExUnit.CaptureIO

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

      output = capture_io(fn -> Mix.Tasks.Argus.run(["cfg", "--modules", ":lists"]) end)
      assert output =~ "cfg_edge"
    end

    test "runs callgraph analysis" do
      skip_without_souffle()

      output = capture_io(fn -> Mix.Tasks.Argus.run(["callgraph", "--modules", "Enum"]) end)
      assert output =~ "call_edge"
    end

    test "parses Erlang module names" do
      skip_without_souffle()

      capture_io(fn -> Mix.Tasks.Argus.run(["cfg", "--modules", ":maps"]) end)
    end
  end
end
