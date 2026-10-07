defmodule Argus.Analyses.TermValidationTest do
  use ExUnit.Case, async: true
  @moduletag :flowlog

  alias Argus.Test.Memo

  setup_all do
    {:ok, results} = Memo.analyze([:term_validation_fixture], :unsafe_input)
    %{results: results}
  end

  test "a complete recursive validator removes executable-term warnings", %{results: results} do
    refute reported?(results, "decode/1")
  end

  test "recursive validation does not bound compressed ETF allocation", %{results: results} do
    assert Enum.any?(results["compressed_etf_from_input"], fn [_, func, _] ->
             func == ":term_validation_fixture:decode/1"
           end)
  end

  test "validation does not prevent atom creation by decoding without safe", %{results: results} do
    assert reported?(results, "without_safe/1")
  end

  test "a validated compiler copy cannot suppress its unchecked sibling", %{results: results} do
    assert reported?(results, "mixed_copies/2")
  end

  defp reported?(results, name) do
    Enum.any?(results["sink_without_request_path"], fn row ->
      (":term_validation_fixture:" <> name) in row
    end)
  end
end
