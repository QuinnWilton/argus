defmodule Argus.Soundness.SequenceBoundsTest do
  use ExUnit.Case, async: true
  @moduletag :flowlog

  alias Argus.Test.Memo

  setup_all do
    {:ok, results} = Memo.analyze([:sequence_bounds_fixture], :unsafe_input)
    %{rows: results["sink_without_request_path"] ++ results["sink_reachable"]}
  end

  test "a finite alphabet also requires the relevant value, all callers and bounded length", %{
    rows: rows
  } do
    for name <- [
          "unbounded/1",
          "unicode_singleton/1",
          "mixed_leaf/1",
          "wrong_field/1",
          "unchecked_tail/1",
          "exported_builder/2",
          "unknown_alphabet/1",
          "unchecked_return/2",
          "exception_value/1",
          "guard_other_copy/2",
          "saved_value/2",
          "partial_tuple/2",
          "broad_alternative/1",
          "unicode_range/1"
        ] do
      assert Enum.any?(rows, &((":sequence_bounds_fixture:" <> name) in &1)), name
    end
  end
end
