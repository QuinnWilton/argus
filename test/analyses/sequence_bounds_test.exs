defmodule Argus.Analyses.SequenceBoundsTest do
  use ExUnit.Case, async: true

  alias Argus.Test.Memo

  setup_all do
    {:ok, results} = Memo.analyze([:sequence_bounds_fixture], :unsafe_input)
    %{rows: results["sink_without_request_path"] ++ results["sink_reachable"]}
  end

  test "recursive alphabets and late length guards bound successful atom conversions", %{
    rows: rows
  } do
    for name <- ["leaf/1", "float_range/1", "guard_alternatives/1"] do
      refute Enum.any?(rows, &((":sequence_bounds_fixture:" <> name) in &1)), name
    end
  end
end
