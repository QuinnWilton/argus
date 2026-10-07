defmodule Argus.Soundness.TermValidationTest do
  use ExUnit.Case, async: true
  @moduletag :flowlog

  alias Argus.Test.Memo

  setup_all do
    {:ok, results} = Memo.analyze([:term_validation_fixture], :unsafe_input)
    %{rows: results["sink_without_request_path"]}
  end

  test "wrong values and unchecked, partial, late or accepting-error validation remain visible",
       %{rows: rows} do
    for name <- [
          "wrong_value/2",
          "ignored/1",
          "accepting_error/1",
          "caught_error/1",
          "partial/2",
          "premature_use/1",
          "unknown_consumer/1"
        ] do
      assert reported?(rows, name), name
    end
  end

  test "all recursive container members and unsafe scalar types must be checked", %{rows: rows} do
    for name <- [
          "shallow/1",
          "missing_head/1",
          "missing_tail/1",
          "partial_tuple/1",
          "missing_map_value/1",
          "ignored_map_verdict/1",
          "accept_port/1",
          "nondecreasing_recursion/1"
        ] do
      assert reported?(rows, name), name
    end
  end

  test "executable uses and helper side effects cannot certify decoded terms", %{rows: rows} do
    for name <- [
          "execute_decoded/1",
          "apply_decoded/1",
          "projected_tuple/1",
          "projected_list/1",
          "helper_execution/1",
          "helper_consumption/1",
          "throw_return/1",
          "returning_exit/1",
          "caught_validator_reason/1",
          "consumed_verdict/1",
          "rejected_payload/1"
        ] do
      assert reported?(rows, name), name
    end
  end

  test "symbolic equalities, error tags and overlapping type guards retain unsafe payloads", %{
    rows: rows
  } do
    for name <- [
          "symbolic_equality/2",
          "error_tuple_return/1",
          "numeric_subtype/1",
          "binary_subtype/1"
        ] do
      assert reported?(rows, name), name
    end
  end

  defp reported?(rows, name), do: Enum.any?(rows, &((":term_validation_fixture:" <> name) in &1))
end
