defmodule Argus.Analyses.HtmlInjectionTest do
  use ExUnit.Case, async: true
  @moduletag :souffle

  alias Argus.Analyses.UnsafeInput.HtmlInjection
  alias Argus.Test.Fixtures.HtmlInjection, as: Fixture
  alias Argus.Test.Memo

  setup_all do
    {:ok, results} = Memo.analyze([Fixture], :unsafe_input)
    %{rows: results["unescaped_html_from_input"]}
  end

  defp reported?(rows, name),
    do: Enum.any?(rows, fn [_id, func, _api] -> String.ends_with?(func, ":" <> name) end)

  test "raw text, stored fields and captured render assigns reach HTML", %{rows: rows} do
    assert reported?(rows, "raw/1")
    assert reported?(rows, "stored/1")
    assert Enum.any?(rows, fn [_id, func, _] -> func =~ "-render/1-fun-" end)
    assert reported?(rows, "highlighted/2")
    assert Enum.any?(rows, fn [_id, func, _] -> func =~ "-captured_fields/6-fun-" end)
  end

  test "same text escaping and inert inline highlighting are safe", %{rows: rows} do
    refute reported?(rows, "escaped/1")
    refute reported?(rows, "safe_highlight/2")
    refute reported?(rows, "safe_inline/1")
    refute reported?(rows, "literal/0")
    refute reported?(rows, "both_branches/3")
    refute reported?(rows, "builtin_binary_conversion/1")
  end

  test "HTML escaping does not prove JavaScript or URL attribute safety", %{rows: rows} do
    assert reported?(rows, "script/1")
    assert reported?(rows, "attribute/1")
    assert reported?(rows, "unsafe_replacement/2")
  end

  test "wrong value, after-use and partial-path escaping remain findings", %{rows: rows} do
    assert reported?(rows, "unrelated/2")
    assert reported?(rows, "after_use/1")
    assert reported?(rows, "one_branch/2")
  end

  test "Phoenix safe tuples and unknown types do not prove escaping", %{rows: rows} do
    assert reported?(rows, "safe_tuple/1")
    assert reported?(rows, "unknown_type/1")
  end

  test "response bodies require HTML content type on the same connection", %{rows: rows} do
    assert reported?(rows, "controller/2")
    assert reported?(rows, "response/2")
    refute reported?(rows, "text_response/2")
    refute reported?(rows, "other_response/3")
  end

  test "finding describes possible stored content without asserting attacker control", %{
    rows: [row | _]
  } do
    finding = HtmlInjection.finding(:unescaped_html_from_input, row)
    assert finding.title == "Unescaped data rendered as HTML"
    assert finding.detail =~ "stored user-authored labels"
    assert finding.detail =~ "does not establish"
  end

  test "same-module returned markup and private response arguments retain safety", %{rows: rows} do
    refute reported?(rows, "local_escaped/1")
    refute reported?(rows, "safe_sink/2")
    refute reported?(rows, "js_sink/2")
    assert reported?(rows, "mixed_sink/2")
  end

  test "JavaScript escaping protects only its exact quote and HTML script context", %{rows: rows} do
    refute reported?(rows, "js_document/1")

    for name <- [
          "js_wrong_quote/1",
          "js_wrong_context/1",
          "js_partial_branch/2",
          "js_missing_close_tag/1",
          "js_wrong_order/1",
          "js_truncated_escape/1",
          "js_split_close_tag/2",
          "js_literal_slash/1",
          "js_after_escape/1"
        ] do
      assert reported?(rows, name), name
    end
  end

  test "rewriting existing markup can introduce script context", %{rows: rows} do
    assert reported?(rows, "replacement_changes_tag/1")
    assert reported?(rows, "replacement_after_highlight/1")
  end

  test "an unconstrained String.Chars result can forge a Phoenix safe tuple", %{rows: rows} do
    assert reported?(rows, "protocol_highlight/2")
    assert reported?(rows, "forged_protocol/1")
    value = %Argus.Test.Fixtures.HtmlProtocolValue{payload: "<script>alert(1)</script>"}
    assert String.Chars.to_string(value) == {:safe, value.payload}
  end
end
