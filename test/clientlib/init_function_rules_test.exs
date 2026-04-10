defmodule Argus.Clientlib.InitFunctionRulesTest do
  use ExUnit.Case

  alias Argus.Extract
  alias Argus.Souffle

  @moduletag :tmp_dir

  defp skip_without_souffle do
    unless Souffle.available?(), do: flunk("souffle not installed")
  end

  defp priv_dl, do: Path.join(:code.priv_dir(:argus), "dl")

  describe "init_function_rules.dl" do
    @tag :tmp_dir
    test "identifies init/1 in behaviour modules", %{tmp_dir: tmp_dir} do
      skip_without_souffle()

      facts_dir = Path.join(tmp_dir, "facts")

      {:ok, _} =
        Extract.run(
          [Argus.Test.Fixtures.MyGenServer],
          facts_dir,
          extractors: [Argus.Extractors.OTP]
        )

      # init_function_rules.dl declares init_function internally.
      # We just include base.dl for function_def, add implements_behaviour,
      # then include the rules file and add .output.
      rules = """
      .include "#{Path.join(priv_dl(), "base.dl")}"

      .decl implements_behaviour(mod: symbol, behaviour: symbol)
      .input implements_behaviour

      .include "#{Path.join(priv_dl(), "clientlib/init_function_rules.dl")}"
      .output init_function
      """

      rules_path = Path.join(tmp_dir, "test_init_fn.dl")
      File.write!(rules_path, rules)

      assert {:ok, results} = Souffle.run(facts_dir, rules_path)

      assert Map.has_key?(results, "init_function")
      init_fns = results["init_function"]
      assert length(init_fns) > 0

      # MyGenServer has init/1.
      assert Enum.any?(init_fns, fn [mod, _func] ->
               mod == "Argus.Test.Fixtures.MyGenServer"
             end)
    end

    @tag :tmp_dir
    test "does not identify init in non-behaviour modules", %{tmp_dir: tmp_dir} do
      skip_without_souffle()

      facts_dir = Path.join(tmp_dir, "facts")

      {:ok, _} = Extract.run([:maps], facts_dir, extractors: [Argus.Extractors.OTP])

      rules = """
      .include "#{Path.join(priv_dl(), "base.dl")}"

      .decl implements_behaviour(mod: symbol, behaviour: symbol)
      .input implements_behaviour

      .include "#{Path.join(priv_dl(), "clientlib/init_function_rules.dl")}"
      .output init_function
      """

      rules_path = Path.join(tmp_dir, "test_init_fn_none.dl")
      File.write!(rules_path, rules)

      assert {:ok, results} = Souffle.run(facts_dir, rules_path)

      # :maps does not implement any behaviour, so no init_function.
      assert results["init_function"] == []
    end
  end
end
