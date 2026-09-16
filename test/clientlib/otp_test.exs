defmodule Argus.Clientlib.OtpTest do
  use ExUnit.Case

  alias Argus.Pipeline
  alias Argus.Souffle

  @moduletag :tmp_dir

  defp skip_without_souffle do
    unless Souffle.available?(), do: flunk("souffle not installed")
  end

  defp priv_dl, do: Path.join(:code.priv_dir(:panoptes), "dl")

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

      {:ok, _} =
        Pipeline.run(modules, facts_dir,
          extractors: [Argus.Extractors.OTP, Argus.Extractors.ApiCalls, Argus.Extractors.ApiCalls]
        )

      # imports.dl reads the staged call graph rather than deriving it.
      :ok = Argus.Analysis.derive_stage0(facts_dir)

      rules = """
      .include "#{Path.join(priv_dl(), "clientlib/imports.dl")}"


      .include "#{Path.join(priv_dl(), "clientlib/otp.dl")}"

      .output init_function
      .output genserver_sync_api
      .output stateful_module_dep
      """

      rules_path = Path.join(tmp_dir, "test_otp.dl")
      File.write!(rules_path, rules)

      assert {:ok, results} = Souffle.run(facts_dir, rules_path)

      # MyGenServer has init/1.
      assert Map.has_key?(results, "init_function")
      init_fns = results["init_function"]
      assert init_fns != []

      assert Enum.any?(init_fns, fn [mod, _func] ->
               mod == "Argus.Test.Fixtures.MyGenServer"
             end)

      # MyGenServer.get_value/1 is a sync API (calls GenServer.call).
      assert Map.has_key?(results, "genserver_sync_api")
      sync_api = results["genserver_sync_api"]
      assert sync_api != []

      # CycleServerA and CycleServerB have mutual dependencies.
      assert Map.has_key?(results, "stateful_module_dep")
      deps = results["stateful_module_dep"]
      assert deps != []
    end
  end
end
