defmodule Argus.Clientlib.CallbacksTest do
  use ExUnit.Case

  alias Argus.Pipeline
  alias Argus.Souffle

  @moduletag :tmp_dir

  defp skip_without_souffle do
    unless Souffle.available?(), do: flunk("souffle not installed")
  end

  defp priv_dl, do: Path.join(:code.priv_dir(:argus), "dl")

  describe "callbacks.dl" do
    @tag :tmp_dir
    test "identifies handle_call and handle_cast functions", %{tmp_dir: tmp_dir} do
      skip_without_souffle()

      facts_dir = Path.join(tmp_dir, "facts")

      {:ok, _} =
        Pipeline.run([Argus.Test.Fixtures.MyGenServer], facts_dir,
          extractors: [Argus.Extractors.OTP]
        )

      rules = """
      .include "#{Path.join(priv_dl(), "clientlib/imports.dl")}"

      .decl implements_behaviour(mod: symbol, behaviour: symbol)
      .input implements_behaviour

      .include "#{Path.join(priv_dl(), "clientlib/callbacks.dl")}"

      .output handle_call_function
      .output handle_cast_function
      """

      rules_path = Path.join(tmp_dir, "test_callbacks.dl")
      File.write!(rules_path, rules)

      assert {:ok, results} = Souffle.run(facts_dir, rules_path)

      # MyGenServer implements handle_call/3 and handle_cast/2.
      assert Map.has_key?(results, "handle_call_function")
      call_fns = results["handle_call_function"]
      assert length(call_fns) > 0

      assert Enum.any?(call_fns, fn [mod, _func] ->
               mod == "Argus.Test.Fixtures.MyGenServer"
             end)

      assert Map.has_key?(results, "handle_cast_function")
      cast_fns = results["handle_cast_function"]
      assert length(cast_fns) > 0

      assert Enum.any?(cast_fns, fn [mod, _func] ->
               mod == "Argus.Test.Fixtures.MyGenServer"
             end)
    end
  end
end
