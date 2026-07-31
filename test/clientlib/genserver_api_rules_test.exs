defmodule Argus.Clientlib.GenserverApiRulesTest do
  use ExUnit.Case

  alias Argus.Pipeline
  alias Argus.Souffle

  @moduletag :tmp_dir

  defp skip_without_souffle do
    unless Souffle.available?(), do: flunk("souffle not installed")
  end

  defp priv_dl, do: Path.join(:code.priv_dir(:argus), "dl")

  describe "genserver_api_rules.dl" do
    @tag :tmp_dir
    test "identifies exported sync API functions", %{tmp_dir: tmp_dir} do
      skip_without_souffle()

      facts_dir = Path.join(tmp_dir, "facts")

      {:ok, _} =
        Pipeline.run([Argus.Test.Fixtures.MyGenServer], facts_dir,
          extractors: [Argus.Extractors.OTP]
        )

      # imports.dl reads the staged call graph rather than deriving it.
      :ok = Argus.Analysis.derive_stage0(facts_dir)

      # Use imports.dl which already declares call_reachable. Then include
      # genserver_api_rules.dl which declares genserver_sync_api. We just
      # need to add the missing input declarations and .output.
      rules = """
      .include "#{Path.join(priv_dl(), "clientlib/imports.dl")}"

      .decl implements_behaviour(mod: symbol, behaviour: symbol)
      .input implements_behaviour

      .decl sync_call(caller_func: symbol, callee_mod: symbol)
      .input sync_call

      .include "#{Path.join(priv_dl(), "clientlib/genserver_api_rules.dl")}"
      .output genserver_sync_api
      """

      rules_path = Path.join(tmp_dir, "test_genserver_api.dl")
      File.write!(rules_path, rules)

      assert {:ok, results} = Souffle.run(facts_dir, rules_path)

      assert Map.has_key?(results, "genserver_sync_api")
      sync_api = results["genserver_sync_api"]
      assert length(sync_api) > 0

      # MyGenServer.get_value/1 calls GenServer.call — it's a sync API function.
      assert Enum.any?(sync_api, fn [func, mod] ->
               String.contains?(func, "get_value") and
                 mod == "Argus.Test.Fixtures.MyGenServer"
             end)
    end
  end
end
