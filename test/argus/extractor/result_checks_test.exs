defmodule Argus.Extractor.ResultChecksTest do
  use ExUnit.Case, async: true

  alias Argus.Extractors.ResultChecks
  alias Argus.Test.Fixtures.ResultChecks, as: Fixture

  setup_all do
    {:ok, facts} = Argus.Pipeline.extract([Fixture], extractors: [ResultChecks])
    %{facts: facts}
  end

  defp uses(facts, name) do
    for [id, func, use, path, kind] <- Map.get(facts, :security_result_use, []),
        String.ends_with?(func, ":" <> name),
        [^id, ^func, "JOSE.JWT:verify/2"] <- facts.security_result,
        do: {id, use, path, kind}
  end

  defp protected?(facts, {id, use, _, _}) do
    Enum.any?(Map.get(facts, :security_result_precondition, []), fn
      [^id, _, ^use, "tuple:0", "true"] -> true
      _ -> false
    end)
  end

  defp payload_uses(facts, name),
    do: Enum.filter(uses(facts, name), &match?({_, _, "tuple:1", "value"}, &1))

  test "shape checks do not establish the success field", %{facts: facts} do
    assert uses = payload_uses(facts, "unchecked/2")
    assert uses != []
    refute Enum.any?(uses, &protected?(facts, &1))
  end

  test "tagged tuple and separate boolean checks protect the same payload", %{facts: facts} do
    for name <- ["tagged/2", "separate_boolean/2", "rejecting/2", "selecting/2"] do
      assert uses = payload_uses(facts, name)
      assert uses != [], name
      assert Enum.all?(uses, &protected?(facts, &1)), name
    end
  end

  test "another invocation, a later check and a partial guard do not protect use", %{facts: facts} do
    for name <- ["wrong_result/3", "after_use/2", "one_branch/3", "catches_rejection/2"] do
      assert uses = payload_uses(facts, name)
      assert uses != [], name
      refute Enum.any?(uses, &protected?(facts, &1)), name
    end
  end

  test "literal success tags are independent of verification API contracts", %{facts: facts} do
    assert Enum.any?(facts.security_result_precondition, fn
             [_, func, _, "tuple:0", ":ok"] -> String.ends_with?(func, ":generic_tag/2")
             _ -> false
           end)
  end

  test "truthiness excludes false without claiming an arbitrary value is true", %{facts: facts} do
    assert [use] = payload_uses(facts, "truthy/2")
    refute protected?(facts, use)
    {id, at, _, _} = use

    assert Enum.any?(facts.security_result_exclusion, fn
             [^id, _, ^at, "tuple:0", "false"] -> true
             _ -> false
           end)
  end

  test "returning or wrapping a whole verdict forwards it", %{facts: facts} do
    for name <- ["forwards/2", "wraps/2"] do
      assert Enum.any?(uses(facts, name), &match?({_, _, "self", "forward"}, &1))
      assert payload_uses(facts, name) == []
    end
  end

  test "raising with a payload is distinct from accepting it", %{facts: facts} do
    assert payload_uses(facts, "raises_payload/2") == []
    assert Enum.any?(uses(facts, "raises_payload/2"), &match?({_, _, "tuple:1", "raise"}, &1))
  end

  test "discarding a scalar verdict differs from testing it", %{facts: facts} do
    discarded = for [_, func, _] <- Map.get(facts, :security_result_discarded, []), do: func
    assert Enum.any?(discarded, &String.ends_with?(&1, ":scalar_ignored/5"))
    refute Enum.any?(discarded, &String.ends_with?(&1, ":scalar_checked/5"))
    refute Enum.any?(discarded, &String.ends_with?(&1, ":forwards/2"))
  end
end
