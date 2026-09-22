defmodule Argus.Analyses.SupervisionTest do
  use ExUnit.Case

  alias Argus.Souffle

  defp skip_without_souffle do
    unless Souffle.available?(), do: flunk("souffle not installed")
  end

  describe "permanent_child_stops_normally" do
    test "a permanent child that stops with :normal is reported; a transient one is not" do
      skip_without_souffle()

      modules = [
        Argus.Test.Fixtures.QuitterSupervisor,
        Argus.Test.Fixtures.TransientQuitterSupervisor,
        Argus.Test.Fixtures.PermanentQuitter
      ]

      assert {:ok, results} = Argus.analyze(modules, :supervision)

      assert [[sup, child, ":normal", site, _sup_site]] =
               results["permanent_child_stops_normally"]

      assert sup == "Argus.Test.Fixtures.QuitterSupervisor"
      assert child == "Argus.Test.Fixtures.PermanentQuitter"
      assert site =~ "PermanentQuitter:handle_call/3#"
    end
  end
end
