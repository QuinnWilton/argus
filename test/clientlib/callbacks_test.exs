defmodule Argus.Clientlib.CallbacksTest do
  use ExUnit.Case, async: true
  @moduletag :flowlog

  alias Argus.Pipeline

  @moduletag :tmp_dir

  defp priv_dl, do: Path.join(:code.priv_dir(:argus_beam), "dl")

  describe "callbacks.dl" do
    @tag :tmp_dir
    test "identifies handle_call and handle_cast functions", %{tmp_dir: tmp_dir} do
      facts_dir = Path.join(tmp_dir, "facts")

      {:ok, _} =
        Pipeline.run([Argus.Test.Fixtures.MyGenServer], facts_dir,
          extractors: [Argus.Extractors.OTP, Argus.Extractors.ApiCalls]
        )

      rules = """
      .include "#{Path.join(priv_dl(), "clientlib/imports.dl")}"
      .include "#{Path.join(priv_dl(), "clientlib/behaviours.dl")}"


      .include "#{Path.join(priv_dl(), "clientlib/callbacks.dl")}"

      .output handle_call_function
      .output handle_cast_function
      """

      rules_path = Path.join(tmp_dir, "test_callbacks.dl")
      File.write!(rules_path, rules)

      assert {:ok, results} = Argus.FlowLog.run(facts_dir, rules_path)

      # MyGenServer implements handle_call/3 and handle_cast/2.
      assert Map.has_key?(results, "handle_call_function")
      call_fns = results["handle_call_function"]
      assert call_fns != []

      assert Enum.any?(call_fns, fn [mod, _func] ->
               mod == "Argus.Test.Fixtures.MyGenServer"
             end)

      assert Map.has_key?(results, "handle_cast_function")
      cast_fns = results["handle_cast_function"]
      assert cast_fns != []

      assert Enum.any?(cast_fns, fn [mod, _func] ->
               mod == "Argus.Test.Fixtures.MyGenServer"
             end)
    end
  end
end
