defmodule Argus.Clientlib.OtpTest do
  use ExUnit.Case

  alias Argus.Extract
  alias Argus.Souffle.CLI

  @moduletag :tmp_dir

  defp skip_without_souffle do
    unless CLI.available?(), do: flunk("souffle not installed")
  end

  defp priv_dl, do: Path.join(:code.priv_dir(:argus), "dl")

  describe "otp.dl" do
    @tag :tmp_dir
    test "identifies init functions and GenServer sync API", %{tmp_dir: tmp_dir} do
      skip_without_souffle()

      facts_dir = Path.join(tmp_dir, "facts")

      modules = [
        Argus.Test.Fixtures.MyGenServer,
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

      .output init_function
      .output genserver_sync_api
      .output stateful_module_dep
      """

      rules_path = Path.join(tmp_dir, "test_otp.dl")
      File.write!(rules_path, rules)

      assert {:ok, results} = CLI.run(facts_dir, rules_path)

      # MyGenServer has init/1.
      assert Map.has_key?(results, "init_function")
      init_fns = results["init_function"]
      assert length(init_fns) > 0

      assert Enum.any?(init_fns, fn [mod, _func] ->
               mod == "Argus.Test.Fixtures.MyGenServer"
             end)

      # MyGenServer.get_value/1 is a sync API (calls GenServer.call).
      assert Map.has_key?(results, "genserver_sync_api")
      sync_api = results["genserver_sync_api"]
      assert length(sync_api) > 0

      # CycleServerA and CycleServerB have mutual dependencies.
      assert Map.has_key?(results, "stateful_module_dep")
      deps = results["stateful_module_dep"]
      assert length(deps) > 0
    end
  end
end
