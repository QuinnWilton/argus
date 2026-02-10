defmodule Argus.Analyses.SupervisionTest do
  use ExUnit.Case

  alias Argus.Souffle.CLI

  defp skip_without_souffle do
    unless CLI.available?(), do: flunk("souffle not installed")
  end

  describe "supervision.dl" do
    test "analyzes supervisor fixtures" do
      skip_without_souffle()

      modules = [
        Argus.Test.Fixtures.GoodSupervisor,
        Argus.Test.Fixtures.BadOrderSupervisor,
        Argus.Test.Fixtures.WorkerA,
        Argus.Test.Fixtures.WorkerB
      ]

      assert {:ok, results} = Argus.analyze(modules, :supervision)

      assert Map.has_key?(results, "suspect_transient_dependency")
      assert Map.has_key?(results, "unlinked_coupled_siblings")
      assert Map.has_key?(results, "wrong_start_order")
    end
  end
end
