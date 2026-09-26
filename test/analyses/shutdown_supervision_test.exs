defmodule Argus.Analyses.ShutdownSupervisionTest do
  use ExUnit.Case, async: true

  alias Argus.Souffle
  alias Argus.Test.Memo

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

      assert {:ok, results} = Memo.analyze(modules, :shutdown)

      assert [[sup, child, ":normal", site, _sup_site]] =
               results["permanent_child_stops_normally"]

      assert sup == "Argus.Test.Fixtures.QuitterSupervisor"
      assert child == "Argus.Test.Fixtures.PermanentQuitter"
      assert site =~ "PermanentQuitter:handle_call/3#"
    end

    test "a shorthand's restart is the one its child's own child_spec/1 states" do
      skip_without_souffle()

      alias Argus.Test.Fixtures.ChildSpecs, as: Specs

      modules = [
        Specs.RestartSup,
        Specs.TransientOwner,
        Specs.ProvisionerLike,
        Specs.PermanentStopper
      ]

      assert {:ok, results} = Memo.analyze(modules, :shutdown)

      # `use GenServer, restart: :transient` and a hand-written transient
      # child_spec/1 a list calls are not restarted after a normal stop;
      # the default is.
      assert for([_sup, child | _] <- results["permanent_child_stops_normally"], do: child) ==
               [inspect(Specs.PermanentStopper)]
    end
  end
end
