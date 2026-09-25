defmodule Argus.Analyses.StartupSupervisionTest do
  use ExUnit.Case, async: true

  alias Argus.Souffle
  alias Argus.Test.Memo
  alias Argus.Test.Rows

  defp skip_without_souffle do
    unless Souffle.available?(), do: flunk("souffle not installed")
  end

  defp later_siblings(results),
    do:
      Rows.where(results, :startup, "blocks_on_peer",
        phase: "init",
        ordering: "later",
        drop: [:phase]
      )

  describe "startup.dl" do
    test "analyzes supervisor fixtures" do
      skip_without_souffle()

      modules = [
        Argus.Test.Fixtures.GoodSupervisor,
        Argus.Test.Fixtures.BadOrderSupervisor,
        Argus.Test.Fixtures.WorkerA,
        Argus.Test.Fixtures.WorkerB
      ]

      assert {:ok, results} = Memo.analyze(modules, :startup)

      assert Map.has_key?(results, "blocks_on_peer")
    end
  end

  describe "blocks_on_peer: a later sibling" do
    test "flags a child whose init sync-calls a later-started sibling" do
      skip_without_souffle()

      modules = [
        Argus.Test.Fixtures.ProcessDepSupervisor,
        Argus.Test.Fixtures.InitProcessCaller,
        Argus.Test.Fixtures.InitDepWorker
      ]

      assert {:ok, results} = Memo.analyze(modules, :startup)

      assert Enum.any?(later_siblings(results), fn [child, dep | _] ->
               String.contains?(child, "InitProcessCaller") and
                 String.contains?(dep, "InitDepWorker")
             end)
    end

    test "a call of unknown place is anchored at the call in init/1, not at its head" do
      skip_without_souffle()

      # Without the supervisor, InitDepWorker's place is unknown: the
      # finding is a note, on the GenServer.call a line below `def init`.
      modules = [Argus.Test.Fixtures.InitProcessCaller, Argus.Test.Fixtures.InitDepWorker]
      {:ok, %{findings: findings}} = Memo.run_analyses(modules, analyses: [:startup])

      assert [finding] =
               Enum.filter(findings, &(&1.title == "init/1 blocks on a synchronous call"))

      assert finding.instr != nil

      {:ok, facts} = Argus.Pipeline.extract(modules)
      line = Argus.Lines.resolve(Argus.Lines.from_facts(facts), finding.instr)
      source = Path.expand("../fixtures/supervision_fixture.ex", __DIR__)

      assert source |> File.read!() |> String.split("\n") |> Enum.at(line - 1) =~
               ":pong = GenServer.call(Argus.Test.Fixtures.InitDepWorker, :ping)"
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

      assert {:ok, results} = Memo.analyze(modules, :startup)

      refute Enum.any?(later_siblings(results), fn [child, _dep | _] ->
               String.contains?(child, "InitPureCaller")
             end)
    end
  end

  describe "supervision shapes" do
    alias Argus.Test.Fixtures.SupervisionShapes, as: Shapes

    test "state written after Supervisor.start_link is noted; before it is not" do
      skip_without_souffle()

      {:ok, r} =
        Memo.analyze([Shapes.LateWarmup, Shapes.EarlyWarmup, Shapes.Conn], :startup)

      funcs = Enum.map(Map.get(r, "post_start_initialization", []), &hd/1) |> Enum.uniq()
      assert funcs == ["Argus.Test.Fixtures.SupervisionShapes.LateWarmup:start_link/1"]
    end
  end
end
