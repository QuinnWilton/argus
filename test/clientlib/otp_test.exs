defmodule Argus.Clientlib.OtpTest do
  use ExUnit.Case, async: true

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
      :ok = Argus.Analysis.derive_points_to(facts_dir)

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

  describe "a behaviour a start names" do
    @tag :tmp_dir
    test "a module a start names the callback module of runs as that behaviour", %{
      tmp_dir: tmp_dir
    } do
      skip_without_souffle()

      facts_dir = Path.join(tmp_dir, "facts")

      # bless_server, bless_bare_sup and bless_statem start themselves
      # without declaring a behaviour; bless_starter starts bless_worker;
      # nothing starts bless_plain, which exports an init/1.
      modules = [
        :bless_server,
        :bless_later,
        :bless_bare_sup,
        :bless_statem,
        :bless_starter,
        :bless_worker,
        :bless_plain
      ]

      {:ok, _} = Pipeline.run(modules, facts_dir, extractors: [Argus.Extractors.OTP])
      :ok = Argus.Analysis.derive_stage0(facts_dir)

      rules = """
      .include "#{Path.join(priv_dl(), "clientlib/imports.dl")}"
      .include "#{Path.join(priv_dl(), "clientlib/otp.dl")}"

      .output behaves_as
      .output init_function
      .output gen_server_like
      """

      rules_path = Path.join(tmp_dir, "started_as.dl")
      File.write!(rules_path, rules)

      assert {:ok, results} = Souffle.run(facts_dir, rules_path)

      behaves = Map.get(results, "behaves_as", [])
      assert [":bless_server", "GenServer"] in behaves
      assert [":bless_bare_sup", "Supervisor"] in behaves
      assert [":bless_statem", "GenStateMachine"] in behaves
      assert [":bless_worker", "GenServer"] in behaves

      inits = results |> Map.get("init_function", []) |> Enum.map(&hd/1)
      assert ":bless_server" in inits
      assert ":bless_bare_sup" in inits
      assert ":bless_statem" in inits
      assert ":bless_worker" in inits
      refute ":bless_plain" in inits

      servers = results |> Map.get("gen_server_like", []) |> Enum.map(&hd/1)
      assert ":bless_server" in servers
      refute ":bless_plain" in servers
    end
  end
end
