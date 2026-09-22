defmodule Argus.Analyses.SupervisionTest do
  use ExUnit.Case

  alias Argus.Souffle

  defp skip_without_souffle do
    unless Souffle.available?(), do: flunk("souffle not installed")
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

      assert Map.has_key?(results, "wrong_start_order")
    end
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

  describe "wrong_start_order" do
    test "flags a child whose init sync-calls a later-started sibling" do
      skip_without_souffle()

      modules = [
        Argus.Test.Fixtures.ProcessDepSupervisor,
        Argus.Test.Fixtures.InitProcessCaller,
        Argus.Test.Fixtures.InitDepWorker
      ]

      assert {:ok, results} = Argus.analyze(modules, :supervision)

      assert Enum.any?(results["wrong_start_order"], fn [_sup, child, dep | _] ->
               String.contains?(child, "InitProcessCaller") and
                 String.contains?(dep, "InitDepWorker")
             end)
    end

    test "does not flag init calling only a pure function in the sibling's module" do
      skip_without_souffle()

      # The Horde.RegistryImpl -> NodeListener.make_members shape: init
      # reaches a function DEFINED in the dependency's module, but it is a
      # pure function — no dependency on the dependency's process, so no
      # start-order hazard.
      modules = [
        Argus.Test.Fixtures.PureDepSupervisor,
        Argus.Test.Fixtures.InitPureCaller,
        Argus.Test.Fixtures.InitDepWorker
      ]

      assert {:ok, results} = Argus.analyze(modules, :supervision)

      refute Enum.any?(results["wrong_start_order"], fn [_sup, child, _dep | _] ->
               String.contains?(child, "InitPureCaller")
             end)
    end
  end

  describe "supervision shapes" do
    alias Argus.Test.Fixtures.SupervisionShapes, as: Shapes

    test "state written after Supervisor.start_link is noted; before it is not" do
      skip_without_souffle()

      {:ok, r} = Argus.analyze([Shapes.LateWarmup, Shapes.EarlyWarmup, Shapes.Conn], :supervision)

      funcs = Enum.map(Map.get(r, "post_start_initialization", []), &hd/1) |> Enum.uniq()
      assert funcs == ["Argus.Test.Fixtures.SupervisionShapes.LateWarmup:start_link/1"]
    end
  end
end
