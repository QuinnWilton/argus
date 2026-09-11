defmodule Argus.Clientlib.StatefulModuleDepRulesTest do
  use ExUnit.Case

  alias Argus.Pipeline
  alias Argus.Souffle

  @moduletag :tmp_dir

  defp skip_without_souffle do
    unless Souffle.available?(), do: flunk("souffle not installed")
  end

  defp priv_dl, do: Path.join(:code.priv_dir(:argus), "dl")

  describe "stateful_module_dep_rules.dl" do
    @tag :tmp_dir
    test "detects mutual sync-call dependencies", %{tmp_dir: tmp_dir} do
      skip_without_souffle()

      facts_dir = Path.join(tmp_dir, "facts")

      modules = [
        Argus.Test.Fixtures.CycleServerA,
        Argus.Test.Fixtures.CycleServerB
      ]

      {:ok, _} = Pipeline.run(modules, facts_dir, extractors: [Argus.Extractors.OTP])
      # imports.dl reads the staged call graph rather than deriving it.
      :ok = Argus.Analysis.derive_stage0(facts_dir)

      rules = """
      .include "#{Path.join(priv_dl(), "clientlib/imports.dl")}"
      .include "#{Path.join(priv_dl(), "clientlib/behaviours.dl")}"


      .include "#{Path.join(priv_dl(), "clientlib/otp.dl")}"

      .output stateful_module_dep
      """

      rules_path = Path.join(tmp_dir, "test_stateful_dep.dl")
      File.write!(rules_path, rules)

      assert {:ok, results} = Souffle.run(facts_dir, rules_path)

      assert Map.has_key?(results, "stateful_module_dep")
      deps = results["stateful_module_dep"]
      assert deps != []

      # CycleServerA depends on CycleServerB and vice versa; the witness
      # is a function of the depending module.
      assert Enum.any?(deps, fn [from, to, witness] ->
               from == "Argus.Test.Fixtures.CycleServerA" and
                 to == "Argus.Test.Fixtures.CycleServerB" and
                 String.starts_with?(witness, "Argus.Test.Fixtures.CycleServerA:")
             end)

      assert Enum.any?(deps, fn [from, to, witness] ->
               from == "Argus.Test.Fixtures.CycleServerB" and
                 to == "Argus.Test.Fixtures.CycleServerA" and
                 String.starts_with?(witness, "Argus.Test.Fixtures.CycleServerB:")
             end)
    end
  end
end
