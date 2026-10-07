defmodule Argus.Soundness.CodeInjectionTest do
  use ExUnit.Case, async: true
  @moduletag :flowlog
  alias Argus.Test.Fixtures.CodeInjection
  alias Argus.Test.Memo

  test "bindings, constant returns and a false flag never become runtime template source" do
    {:ok, results} = Memo.analyze([CodeInjection], :unsafe_input)
    funcs = for [_, func, _, _, _] <- results["runtime_template_evaluation"], do: func

    for name <- [
          "callback_bindings/2",
          "literal_template/1",
          "constant_callback/1",
          "opaque_external/1",
          "safe_helper/2",
          "guarded_false/3",
          "discarded_callback/2"
        ] do
      refute Enum.any?(funcs, &String.ends_with?(&1, ":" <> name)), name
    end

    for name <- ["callback_bindings/2", "literal_template/1", "discarded_callback/2"] do
      refute Enum.any?(results["sink_without_request_path"], fn [_, func | _] ->
               String.ends_with?(func, ":" <> name)
             end),
             name
    end
  end
end
