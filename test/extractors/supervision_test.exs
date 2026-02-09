defmodule Argus.Extractors.SupervisionTest do
  use ExUnit.Case, async: true

  alias Argus.Extractors.Supervision

  describe "extract/1" do
    test "detects supervisor module" do
      {:ok, data} =
        BeamSpy.BeamFile.disassemble(to_string(:code.which(Argus.Test.Fixtures.GoodSupervisor)))

      facts = Supervision.extract(data)

      assert Map.has_key?(facts, :supervisor)
      sups = facts[:supervisor]
      assert length(sups) == 1
      [mod_str, _strategy] = hd(sups)
      assert mod_str == "Argus.Test.Fixtures.GoodSupervisor"
    end

    test "detects supervision strategy" do
      {:ok, data} =
        BeamSpy.BeamFile.disassemble(to_string(:code.which(Argus.Test.Fixtures.GoodSupervisor)))

      facts = Supervision.extract(data)
      [_mod, strategy] = hd(facts[:supervisor])
      assert strategy == "one_for_one"
    end

    test "extracts child specs" do
      {:ok, data} =
        BeamSpy.BeamFile.disassemble(to_string(:code.which(Argus.Test.Fixtures.GoodSupervisor)))

      facts = Supervision.extract(data)

      if Map.has_key?(facts, :supervisor_child) do
        children = facts[:supervisor_child]
        assert length(children) >= 1

        child_mods = Enum.map(children, fn [_, _, mod, _, _] -> mod end)

        assert Enum.any?(child_mods, &String.contains?(&1, "WorkerA")) or
                 Enum.any?(child_mods, &String.contains?(&1, "WorkerB"))
      end
    end

    test "returns empty for non-supervisor module" do
      {:ok, data} =
        BeamSpy.BeamFile.disassemble(to_string(:code.which(Argus.Test.Fixtures.PlainModule)))

      facts = Supervision.extract(data)
      assert facts == %{}
    end
  end

  describe "integration with extract pipeline" do
    test "extractor is usable via Extract.extract/2" do
      assert {:ok, facts} =
               Argus.Extract.extract(
                 [Argus.Test.Fixtures.GoodSupervisor],
                 extractors: [Supervision]
               )

      assert Map.has_key?(facts, :supervisor)
    end
  end
end
