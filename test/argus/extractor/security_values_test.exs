defmodule Argus.Extractor.SecurityValuesTest do
  use ExUnit.Case, async: true

  alias Argus.Extractors.SecurityValues
  alias Argus.Test.Fixtures.SecurityValues, as: Fixture

  setup_all do
    {:ok, facts} = Argus.Pipeline.extract([Fixture], extractors: [SecurityValues])
    %{facts: facts}
  end

  defp args(facts, function) do
    for [id, func, pos, value] <- Map.get(facts, :security_arg_value, []),
        String.ends_with?(func, ":" <> function),
        [^id, _] <- consume_sites(facts),
        do: {pos, value}
  end

  defp consume_sites(facts) do
    for [id, _, name, _] <- Map.get(facts, :local_call, []),
        String.contains?(name, ":consume/"),
        do: [id, name]
  end

  defp limits(facts, function) do
    for [id, func, pos, kind, limit] <- Map.get(facts, :security_arg_limit, []),
        String.ends_with?(func, ":" <> function),
        [^id, _] <- consume_sites(facts),
        do: {pos, kind, limit}
  end

  defp safe(facts, function) do
    for [id, func, pos, property] <- Map.get(facts, :security_arg_safe, []),
        String.ends_with?(func, ":" <> function),
        [^id, _] <- consume_sites(facts),
        do: {pos, property}
  end

  test "field identity retains its containing map", %{facts: facts} do
    assert [{"0", one}, {"1", two}] = Enum.sort(args(facts, "same_field/2"))
    refute one == two
    assert [^one, first, "map", ":name"] = Enum.find(facts.security_value_field, &(hd(&1) == one))

    assert [^two, second, "map", ":name"] =
             Enum.find(facts.security_value_field, &(hd(&1) == two))

    refute first == second
  end

  test "tuple fields retain different indexes of the same result", %{facts: facts} do
    assert [{"0", verified}, {"1", claims}] = Enum.sort(args(facts, "tuple_fields/1"))

    assert [^verified, parent, "tuple", "0"] =
             Enum.find(facts.security_value_field, &(hd(&1) == verified))

    assert [^claims, ^parent, "tuple", "1"] =
             Enum.find(facts.security_value_field, &(hd(&1) == claims))
  end

  test "two calls to the same function retain different result identities", %{facts: facts} do
    assert [{"0", first}, {"1", second}] = Enum.sort(args(facts, "separate_results/2"))
    refute first == second
    origins = facts.security_value_origin
    assert [^first, _, "call", first_site] = Enum.find(origins, &(hd(&1) == first))
    assert [^second, _, "call", second_site] = Enum.find(origins, &(hd(&1) == second))
    refute first_site == second_site
  end

  test "size limits belong to the same value on every path before use", %{facts: facts} do
    assert limits(facts, "bounded/1") == [{"0", "byte_size", "4096"}]
    assert limits(facts, "rejects_large/1") == [{"0", "byte_size", "4095"}]
    assert limits(facts, "wrong_value/2") == []
    assert limits(facts, "checked_after/1") == []
    assert limits(facts, "partial_guard/2") == []
    assert limits(facts, "rescued_guard/1") == []
  end

  test "basename only describes the returned value on every reaching path", %{facts: facts} do
    assert safe(facts, "basename/1") == [{"0", "path_basename"}]
    assert safe(facts, "basename_one_branch/2") == []
    assert safe(facts, "basename_both_branches/3") == [{"0", "path_basename"}]
    assert safe(facts, "expanded/1") == []
    assert safe(facts, "unrelated_basename/2") == [{"0", "path_basename"}]
  end

  test "HTML text escaping is separate from raw markup and SQL replacement", %{facts: facts} do
    assert safe(facts, "html/1") == [{"0", "html_text"}]
    assert safe(facts, "html_binary/1") == [{"0", "html_text"}]
    assert safe(facts, "html_concat/1") == [{"0", "html_text"}]
    assert safe(facts, "phoenix_html/1") == [{"0", "html_text"}]
    assert safe(facts, "phoenix_safe_tuple/1") == []
    assert safe(facts, "phoenix_unknown/1") == []
    assert safe(facts, "raw_html/1") == []
    assert safe(facts, "replaced/1") == []
  end

  test "unknown operations cannot prove safety and literal spelling is stable" do
    instructions = [
      {:func_info, {:atom, Fixture}, {:atom, :unknown}, 1},
      {:label, 1},
      {:unknown_write, {:x, 0}},
      :return
    ]

    refute SecurityValues.safe_at?(instructions, 3, {:x, 0}, "html_text")
    refute SecurityValues.safe_at?(instructions, 3, {:x, 0}, "arbitrary_property")

    assert SecurityValues.identity_at(instructions, 2, {:literal, %{b: 2, a: 1}}) ==
             {:literal, %{a: 1, b: 2}}
  end
end
