defmodule Argus.Soundness.SqlInjectionTest do
  use ExUnit.Case, async: true

  alias Argus.Test.Fixtures.SqlComments
  alias Argus.Test.Fixtures.SqlInjection
  alias Argus.Test.Fixtures.SqlRepoApplication
  alias Argus.Test.Fixtures.SqlRepoConstructed
  alias Argus.Test.Fixtures.SqlRepoGenerated
  alias Argus.Test.Fixtures.SqlRepoMixed
  alias Argus.Test.Fixtures.SqlRepoTwoCalls
  alias Argus.Test.Memo

  test "escaping and validators cannot protect a different context, value, branch, or later use" do
    {:ok, results} =
      Memo.analyze(
        [
          SqlInjection,
          SqlComments,
          SqlRepoGenerated,
          SqlRepoConstructed,
          SqlRepoMixed,
          SqlRepoTwoCalls,
          SqlRepoApplication
        ],
        :unsafe_input
      )

    rows = results["sql_injection"]

    for name <- [
          "dollar/2",
          "tagged_dollar/2",
          "fresh_unsafe_identifier/2",
          "fresh_wrong_body/3",
          "truncated_delimiter/2",
          "raw_integer_tag/2",
          "callback_state/1",
          "wrong_replace/2",
          "escaped_elsewhere/3",
          "partial_escape/3",
          "unknown_escape_branch/3",
          "first_quote_only/2",
          "escaped_then_changed/2",
          "unknown_dialect/2",
          "mysql_quotes/2",
          "nested_comment/2",
          "line_comment/2",
          "ambiguous_backslash/2",
          "wrong_value/2",
          "after_use/1",
          "one_branch/2",
          "rescued_validation/1",
          "non_rejecting/1",
          "changed_comment/2",
          "wrong_field/1",
          "incomplete/1",
          "added_comment/1",
          "joined_separator/2",
          "joined_identifiers/3",
          "joined_unknown_mapper/4"
        ] do
      assert Enum.any?(rows, fn [_, func, _] -> String.ends_with?(func, ":#{name}") end), name
    end
  end
end
