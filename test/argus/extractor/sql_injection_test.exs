defmodule Argus.Extractor.SqlInjectionTest do
  use ExUnit.Case, async: true

  alias Argus.Extractors.SqlInjection
  alias Argus.Test.Fixtures.SqlComments
  alias Argus.Test.Fixtures.SqlInjection, as: Fixture

  setup_all do
    {:ok, facts} = Argus.Pipeline.extract([Fixture, SqlComments], extractors: [SqlInjection])
    %{facts: facts}
  end

  defp unsafe(facts, name) do
    safe = MapSet.new(Map.get(facts, :sql_input_safe, []))

    for [_id, function, context, _param] = row <- Map.get(facts, :sql_input, []),
        String.ends_with?(function, ":#{name}"),
        not MapSet.member?(safe, row),
        uniq: true,
        do: context
  end

  test "literal statements and bound parameters are not SQL construction", %{facts: facts} do
    assert unsafe(facts, "literal/1") == []
    assert unsafe(facts, "bound/2") == []
    assert unsafe(facts, "constant_helper/2") == []
    assert unsafe(facts, "dynamic/2") == ["statement"]
    assert unsafe(facts, "value/2") == ["string"]
    assert unsafe(facts, "comment/2") == ["comment"]
  end

  test "exact identifier escaping follows a helper's returned bytes", %{facts: facts} do
    assert unsafe(facts, "identifier/2") == ["identifier"]
    assert unsafe(facts, "escaped_identifier/2") == []
    assert unsafe(facts, "wrong_replace/2") == ["identifier"]
    assert unsafe(facts, "escaped_elsewhere/3") == ["identifier"]
    assert unsafe(facts, "partial_escape/3") == ["identifier"]
    assert unsafe(facts, "unknown_escape_branch/3") == ["identifier"]
    assert unsafe(facts, "first_quote_only/2") == ["identifier"]
    assert unsafe(facts, "escaped_then_changed/2") == ["identifier"]
    assert unsafe(facts, "unknown_dialect/2") == ["statement"]
    assert unsafe(facts, "mysql_quotes/2") == ["string"]
    assert unsafe(facts, "nested_comment/2") == ["comment"]
    assert unsafe(facts, "line_comment/2") == ["comment"]
    assert unsafe(facts, "ambiguous_backslash/2") != []
  end

  test "identifier quoting does not protect an outer dollar delimiter", %{facts: facts} do
    assert unsafe(facts, "dollar/2") == ["dollar_quote"]
    assert unsafe(facts, "tagged_dollar/2") == ["dollar_quote"]
    assert unsafe(facts, "callback_state/1") == ["dollar_quote"]
    assert unsafe(facts, "captured/3") == ["string"]
    assert unsafe(facts, "fresh_dollar/2") == []
    assert unsafe(facts, "fresh_unsafe_identifier/2") == ["identifier"]
    assert unsafe(facts, "fresh_wrong_body/3") != []
    assert unsafe(facts, "truncated_delimiter/2") != []
    assert unsafe(facts, "raw_integer_tag/2") != []
  end

  test "comment validation must precede persistence of the same options", %{facts: facts} do
    assert unsafe(facts, "envelope/1") == ["comment"]
    assert unsafe(facts, "validated/1") == []
    assert unsafe(facts, "wrong_value/2") == ["comment"]
    assert unsafe(facts, "after_use/1") == ["comment"]
    assert unsafe(facts, "one_branch/2") == ["comment"]
    assert unsafe(facts, "rescued_validation/1") == ["comment"]
    assert unsafe(facts, "non_rejecting/1") == ["comment"]
    assert unsafe(facts, "changed_comment/2") == ["comment"]
    assert unsafe(facts, "wrong_field/1") == ["comment"]
    assert unsafe(facts, "incomplete/1") == ["comment"]
    assert unsafe(facts, "added_comment/1") == ["comment"]
    assert unsafe(facts, "removed_comment/1") == []
  end

  test "joins retain separators separately from mapped and escaped values", %{facts: facts} do
    assert unsafe(facts, "joined_separator/2") == ["statement"]
    assert unsafe(facts, "joined_identifiers/3") == ["statement"]
    assert unsafe(facts, "joined_unknown_mapper/4") == ["statement"]

    for function <- [
          "joined_literal_separator/2",
          "joined_empty/2",
          "joined_singleton/2",
          "joined_without_separator/2"
        ] do
      assert unsafe(facts, function) == [], function
    end
  end
end
