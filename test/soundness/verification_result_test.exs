defmodule Argus.Soundness.VerificationResultTest do
  use ExUnit.Case, async: true
  @moduletag :flowlog

  alias Argus.Test.Fixtures.ResultChecks
  alias Argus.Test.Fixtures.Verification
  alias Argus.Test.Memo

  setup_all do
    {:ok, results} = Memo.analyze([ResultChecks, Verification], :unsafe_input)

    funcs =
      for [_, func, _, _, _] <- results["unchecked_crypto_verification"],
          do: func

    %{funcs: funcs}
  end

  test "same-result success checks and forwarding preserve safe cases", %{funcs: funcs} do
    for name <- [
          "ResultChecks:tagged/2",
          "ResultChecks:separate_boolean/2",
          "ResultChecks:truthy/2",
          "ResultChecks:selecting/2",
          "ResultChecks:rejecting/2",
          "ResultChecks:forwards/2",
          "ResultChecks:wraps/2",
          "ResultChecks:raises_payload/2",
          "ResultChecks:scalar_checked/5",
          "Verification:strict_checked/3",
          "Verification:claim_checked/2",
          "Verification:verdict_forwarded/2",
          "Verification:verdict_passed/2",
          "Verification:public_key_checked/3",
          "Verification:crypto_returned/3"
        ] do
      refute Enum.any?(funcs, &String.ends_with?(&1, name)), name
    end
  end

  test "nearby wrong-result, partial, late and caught checks remain findings", %{funcs: funcs} do
    for name <- [
          "ResultChecks:wrong_result/3",
          "ResultChecks:after_use/2",
          "ResultChecks:one_branch/3",
          "ResultChecks:catches_rejection/2",
          "Verification:different_verdict/3",
          "Verification:accepts_failed_verdict/2",
          "Verification:forwarded_then_used/2"
        ] do
      assert Enum.any?(funcs, &String.ends_with?(&1, name)), name
    end
  end
end
