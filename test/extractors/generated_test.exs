defmodule Argus.Extractors.GeneratedTest do
  use ExUnit.Case, async: true

  alias Argus.Extractors.Generated
  alias Argus.Test.Fixtures.LateMessage

  defp facts(mod) do
    {:ok, facts} = Argus.Pipeline.extract([mod], extractors: [Generated])
    facts
  end

  describe "macro_written" do
    test "a function whose every clause a macro wrote" do
      assert ["#{inspect(LateMessage.Warmer)}:handle_info/2"] in facts(LateMessage.Warmer)[
               :macro_written
             ]
    end

    test "a macro's clause ahead of the module's own marks the definition, not every clause" do
      facts = facts(LateMessage.MixedHandler)
      func = "#{inspect(LateMessage.MixedHandler)}:handle_info/2"

      assert Enum.any?(facts[:macro_generated], &match?([^func, _], &1))
      refute [func] in Map.get(facts, :macro_written, [])
    end
  end
end
