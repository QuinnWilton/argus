defmodule Argus.Soundness.ExposurePrecisionTest do
  use ExUnit.Case, async: true

  alias Argus.Test.Fixtures.SecretPrecision, as: S

  defmodule Oracle do
    @behaviour Argus.Priors.Oracle

    @impl true
    def ask(request, _opts) do
      answers =
        for {id, %{type: "choice"}} <- request.questions, into: %{} do
          {id,
           %{
             "type" => "choice",
             "choice" => "credential",
             "confidence" => 0.99,
             "probabilities" => %{"credential" => 0.99}
           }}
        end

      {:ok, %{answers: answers, usage: %{}, model: request.model, request_id: nil}}
    end
  end

  @tag :tmp_dir
  test "a secret prior cannot turn a boolean into credential material, but strings remain", %{
    tmp_dir: dir
  } do
    assert {:ok, report} =
             Argus.Findings.run([S.BooleanToken, S.Values],
               analyses: [:exposure],
               priors: :live,
               priors_opts: [
                 oracle: Oracle,
                 cache_dir: dir,
                 model: "exposure-precision",
                 questions: [Argus.Priors.Questions.Sensitivity]
               ]
             )

    assert report.degraded == []

    fields = for finding <- report.findings, do: {finding.module, finding.at_source}
    assert {S.Values, ":totp_seed"} in fields
    assert {S.Values, ":public_refresh_token"} in fields
    assert {S.BooleanToken, ":access_token"} in fields
    refute {S.BooleanToken, ":totp_seed"} in fields
    refute {S.BooleanToken, ":public_refresh_token"} in fields
    refute {S.BooleanToken, ":token"} in fields
  end
end
