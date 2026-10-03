defmodule Argus.Extractor.CodeInjectionTest do
  use ExUnit.Case, async: true

  alias Argus.Extractors.CodeInjection
  alias Argus.Extractors.ParamFlow
  alias Argus.Test.Fixtures.CodeInjection, as: Fixture

  test "runtime origins keep invocation IDs without leaking into parameter facts" do
    assert {:ok, facts} =
             Argus.Pipeline.extract([Fixture], extractors: [ParamFlow, CodeInjection])

    assert Enum.any?(facts.call_arg_runtime, fn [id, func, pos, source, source_func] ->
             String.ends_with?(func, ":callback_template/2") and pos == "0" and
               func == source_func and id != source and
               match?({:ok, _}, Argus.InstrId.parse(source))
           end)

    for relation <- [:call_arg_param, :sink_arg_derived],
        [_, _, pos, param] <- facts[relation] do
      assert {_, ""} = Integer.parse(pos)
      assert {_, ""} = Integer.parse(param)
    end

    assert Enum.any?(facts.code_site_gate, fn [_, func, pos, value] ->
             String.ends_with?(func, ":evaluate/3") and pos == "2" and value == "true"
           end)
  end
end
