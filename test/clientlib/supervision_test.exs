defmodule Argus.Clientlib.SupervisionTest do
  use ExUnit.Case

  alias Argus.Pipeline
  alias Argus.Souffle

  @moduletag :tmp_dir

  defp skip_without_souffle do
    unless Souffle.available?(), do: flunk("souffle not installed")
  end

  defp priv_dl, do: Path.join(:code.priv_dir(:argus), "dl")

  describe "supervision.dl" do
    @tag :tmp_dir
    test "computes child_subtree and init_reaches", %{tmp_dir: tmp_dir} do
      skip_without_souffle()

      facts_dir = Path.join(tmp_dir, "facts")

      modules = [
        Argus.Test.Fixtures.GoodSupervisor,
        Argus.Test.Fixtures.WorkerA,
        Argus.Test.Fixtures.WorkerB
      ]

      {:ok, _} =
        Pipeline.run(modules, facts_dir,
          extractors: [Argus.Extractors.OTP, Argus.Extractors.Supervision]
        )

      # imports.dl reads the staged call graph rather than deriving it.
      :ok = Argus.Analysis.derive_stage0(facts_dir)

      rules = """
      .include "#{Path.join(priv_dl(), "clientlib/imports.dl")}"

      .decl implements_behaviour(mod: symbol, behaviour: symbol)
      .input implements_behaviour

      .decl sync_call(caller_func: symbol, callee_mod: symbol)
      .input sync_call

      .decl async_cast(caller_func: symbol, callee_mod: symbol)
      .input async_cast

      .decl supervisor_child(sup: symbol, position: number, child_mod: symbol, restart: symbol, type: symbol)
      .input supervisor_child

      .decl dynamic_child(sup: symbol, child_mod: symbol, caller_func: symbol)
      .input dynamic_child

      .include "#{Path.join(priv_dl(), "clientlib/otp.dl")}"
      .include "#{Path.join(priv_dl(), "clientlib/supervision.dl")}"

      .output child_subtree
      .output init_reaches
      """

      rules_path = Path.join(tmp_dir, "test_supervision.dl")
      File.write!(rules_path, rules)

      assert {:ok, results} = Souffle.run(facts_dir, rules_path)

      # GoodSupervisor has WorkerA and WorkerB as children.
      assert Map.has_key?(results, "child_subtree")
      subtree = results["child_subtree"]
      assert length(subtree) > 0

      # WorkerA and WorkerB should appear as children of GoodSupervisor.
      assert Enum.any?(subtree, fn [sup, _branch, child] ->
               sup == "Argus.Test.Fixtures.GoodSupervisor" and
                 child == "Argus.Test.Fixtures.WorkerA"
             end)

      assert Enum.any?(subtree, fn [sup, _branch, child] ->
               sup == "Argus.Test.Fixtures.GoodSupervisor" and
                 child == "Argus.Test.Fixtures.WorkerB"
             end)
    end
  end
end
