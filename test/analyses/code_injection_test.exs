defmodule Argus.Analyses.CodeInjectionTest do
  use ExUnit.Case, async: true
  alias Argus.Test.Fixtures.CodeInjection
  alias Argus.Test.Memo

  setup_all do
    {:ok, results} = Memo.analyze([CodeInjection], :unsafe_input)
    %{results: results}
  end

  test "callback text is executable source through fields and same-module helpers", %{
    results: results
  } do
    funcs = for [_, func, _, _, _] <- results["runtime_template_evaluation"], do: func

    for name <- [
          "callback_template/2",
          "unsafe_helper/2",
          "mixed_helper/3",
          "wrong_flag/3",
          "wrong_value_gate/3",
          "partially_checked/3",
          "tuple_content/2",
          "callback_result/2",
          "returned_via_mapping/2"
        ] do
      assert Enum.any?(funcs, &String.ends_with?(&1, ":" <> name)), name
    end
  end

  test "EEx evaluators and compilers participate in the existing code sink analysis", %{
    results: results
  } do
    rows = results["sink_without_request_path"]

    assert Enum.any?(rows, fn [_, func, api, kind | _] ->
             String.ends_with?(func, ":dynamic_template/1") and kind == "code" and
               api == "EEx.eval_string/2"
           end)

    assert Enum.any?(rows, fn [_, func, api, kind | _] ->
             String.ends_with?(func, ":compiled_template/1") and kind == "code" and
               api == "EEx.compile_string/1"
           end)
  end
end
