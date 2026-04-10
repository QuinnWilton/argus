defmodule Mix.Tasks.ArgusTest do
  use ExUnit.Case

  import ExUnit.CaptureIO

  alias Argus.Souffle

  defp skip_without_souffle do
    unless Souffle.available?(), do: flunk("souffle not installed")
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

    test "runs supervision analysis with --modules" do
      skip_without_souffle()

      output =
        capture_io(fn ->
          Mix.Tasks.Argus.run(["supervision", "--modules", "Argus.Test.Fixtures.AppSupervisor"])
        end)

      assert output =~ "supervision" or output =~ "==="
    end

    test "runs unlinked_spawn analysis" do
      skip_without_souffle()

      output =
        capture_io(fn ->
          Mix.Tasks.Argus.run([
            "unlinked_spawn",
            "--modules",
            "Argus.Test.Fixtures.UnlinkedSpawner"
          ])
        end)

      assert output =~ "unlinked_spawn" or output =~ "==="
    end

    test "parses Erlang module names" do
      skip_without_souffle()

      capture_io(fn -> Mix.Tasks.Argus.run(["unlinked_spawn", "--modules", ":maps"]) end)
    end

    test "--format json produces inspected map" do
      skip_without_souffle()

      output =
        capture_io(fn ->
          Mix.Tasks.Argus.run(["unlinked_spawn", "--modules", ":maps", "--format", "json"])
        end)

      assert output =~ "%{"
    end

    test "--fail-above 0 raises when results exist" do
      skip_without_souffle()

      assert_raise Mix.Error, ~r/threshold/, fn ->
        capture_io(fn ->
          Mix.Tasks.Argus.run([
            "unlinked_spawn",
            "--modules",
            "Argus.Test.Fixtures.UnlinkedSpawner",
            "--fail-above",
            "0"
          ])
        end)
      end
    end
  end
end
