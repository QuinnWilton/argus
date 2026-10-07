defmodule Argus.Analyses.VerificationTest do
  use ExUnit.Case, async: true
  @moduletag :flowlog

  alias Argus.Analyses.UnsafeInput
  alias Argus.Test.Fixtures.ResultChecks
  alias Argus.Test.Fixtures.Verification
  alias Argus.Test.Memo

  setup_all do
    {:ok, results} = Memo.analyze([ResultChecks, Verification], :unsafe_input)
    %{rows: results["unchecked_crypto_verification"], results: results}
  end

  test "unchecked payloads and ignored scalar verdicts are detected", %{rows: rows} do
    funcs = Enum.map(rows, fn [_, func, _, _, _] -> func end)

    for name <- [
          "ResultChecks:unchecked/2",
          "ResultChecks:scalar_ignored/5",
          "Verification:strict_unchecked/3",
          "Verification:jws_unchecked/2",
          "Verification:claim_unchecked/2",
          "Verification:public_key_ignored/3",
          "Verification:crypto_ignored/3"
        ] do
      assert Enum.any?(funcs, &String.ends_with?(&1, name)), name
    end
  end

  test "a verification call produces one finding despite multiple payload uses", %{
    results: results
  } do
    findings = Argus.Findings.build(UnsafeInput, results)

    assert [_] =
             Enum.filter(findings, fn finding ->
               finding.title == "Cryptographic verification result is not enforced" and
                 finding.mfa == {Verification, :twice_unchecked, 2}
             end)
  end

  test "findings anchor verification and the specific unprotected operation", %{rows: rows} do
    for kind <- ["payload", "discarded"] do
      row = Enum.find(rows, &(List.last(&1) == kind))
      finding = UnsafeInput.finding(:unchecked_crypto_verification, row)
      assert finding.severity == :error
      assert finding.title == "Cryptographic verification result is not enforced"
      assert finding.instr == Argus.Findings.at_instr(hd(row)).instr
      assert [%{instr: use}] = finding.related
      assert use == Argus.Findings.at_instr(Enum.at(row, 3)).instr
      assert finding.help != []
    end
  end
end
