defmodule Argus.Clientlib.StatefulModuleDepRulesTest do
  use ExUnit.Case

  alias Argus.Extract
  alias Argus.Souffle.CLI

  @moduletag :tmp_dir

  defp skip_without_souffle do
    unless CLI.available?(), do: flunk("souffle not installed")
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

      {:ok, _} = Extract.run(modules, facts_dir, extractors: [Argus.Extractors.OTP])

      rules = """
      .include "#{Path.join(priv_dl(), "clientlib/imports.dl")}"

      .decl implements_behaviour(mod: symbol, behaviour: symbol)
      .input implements_behaviour

      .decl sync_call(caller_func: symbol, callee_mod: symbol)
      .input sync_call

      .decl async_cast(caller_func: symbol, callee_mod: symbol)
      .input async_cast

      .include "#{Path.join(priv_dl(), "clientlib/otp.dl")}"

      .output stateful_module_dep
      """

      rules_path = Path.join(tmp_dir, "test_stateful_dep.dl")
      File.write!(rules_path, rules)

      assert {:ok, results} = CLI.run(facts_dir, rules_path)

      assert Map.has_key?(results, "stateful_module_dep")
      deps = results["stateful_module_dep"]
      assert length(deps) > 0

      # CycleServerA depends on CycleServerB and vice versa.
      assert Enum.any?(deps, fn [from, to] ->
               from == "Argus.Test.Fixtures.CycleServerA" and
                 to == "Argus.Test.Fixtures.CycleServerB"
             end)

      assert Enum.any?(deps, fn [from, to] ->
               from == "Argus.Test.Fixtures.CycleServerB" and
                 to == "Argus.Test.Fixtures.CycleServerA"
             end)
    end
  end
end
