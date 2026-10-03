defmodule Argus.Analyses.EtfAllocationTest do
  use ExUnit.Case, async: true

  alias Argus.Analyses.UnsafeInput.EtfAllocation
  alias Argus.Test.Fixtures.EtfAllocation, as: Fixture
  alias Argus.Test.Memo

  setup_all do
    {:ok, results} =
      Memo.analyze(
        [Fixture, Fixture.ExportedDelegate, Fixture.CapturedDelegate, Fixture.PrivateDelegate],
        :unsafe_input
      )

    %{rows: results["compressed_etf_from_input"]}
  end

  defp reported?(rows, name),
    do: Enum.any?(rows, fn [_id, func, _api] -> String.ends_with?(func, ":" <> name) end)

  test "safe options and compressed-input limits do not prevent allocation", %{rows: rows} do
    assert reported?(rows, "direct/1")
    assert reported?(rows, "safe_option/1")
    assert reported?(rows, "encoded_cap/1")
    assert reported?(rows, "non_executable/1")
    refute reported?(rows, "fixed_literal/0")
  end

  test "same-byte prefix rejection works directly and through a checked local predicate", %{
    rows: rows
  } do
    refute reported?(rows, "prefix/1")
    refute reported?(rows, "helper/1")
    refute reported?(rows, "checked_and_literal/1")
  end

  test "wrong values, late checks and one guarded path do not prove safety", %{rows: rows} do
    assert reported?(rows, "wrong_value/2")
    assert reported?(rows, "late/1")
    assert reported?(rows, "partial/2")
  end

  test "an exported delegate remains an independent entry when every local caller guards it", %{
    rows: rows
  } do
    assert Enum.any?(rows, fn [_id, func, _api] ->
             String.ends_with?(func, ".ExportedDelegate:decode/1")
           end)

    refute Enum.any?(rows, fn [_id, func, _api] ->
             String.ends_with?(func, ".ExportedDelegate:guarded/1")
           end)
  end

  test "a guarded direct caller cannot hide a captured decoder", %{rows: rows} do
    assert Enum.any?(rows, fn [_id, func, _api] ->
             String.ends_with?(func, ".CapturedDelegate:decode/1")
           end)

    refute Enum.any?(rows, fn [_id, func, _api] ->
             String.ends_with?(func, ".CapturedDelegate:guarded/1") or
               String.contains?(func, ".PrivateDelegate:")
           end)
  end

  test "catching rejection or changing the checked bytes preserves the finding", %{rows: rows} do
    assert reported?(rows, "rescued/1")
    assert reported?(rows, "rescued_prefix/1")
    assert reported?(rows, "changed_bytes/1")
  end

  test "another prefix and an exact two-byte pattern do not exclude compressed ETF", %{rows: rows} do
    assert reported?(rows, "wrong_prefix/1")
    assert reported?(rows, "exact_short/1")
  end

  test "finding explains why safe and non-executable checks do not bound allocation", %{
    rows: [row | _]
  } do
    finding = EtfAllocation.finding(:compressed_etf_from_input, row)
    assert finding.title == "Compressed ETF allocation from external input"
    assert finding.detail =~ "before [:safe]"
    assert Enum.any?(finding.help, &(&1 =~ "<<131, 80"))
  end
end
