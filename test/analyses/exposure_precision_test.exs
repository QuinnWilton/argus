defmodule Argus.Analyses.ExposurePrecisionTest do
  use ExUnit.Case, async: true

  alias Argus.Analyses.Exposure
  alias Argus.Test.Fixtures.SecretPrecision, as: S
  alias Argus.Test.Memo

  @mods [S.BooleanToken, S.Values, Argus.Test.Support.HashedSecret]

  @tag :souffle
  test "known boolean schema fields are metadata, while unknown and value types remain" do
    assert {:ok, results} = Memo.analyze(@mods, :exposure)

    fields =
      for [mod, field | _] <- results["unredacted_secret"],
          do: {mod, field}

    assert {inspect(S.BooleanToken), ":access_token"} in fields
    refute {inspect(S.BooleanToken), ":public_refresh_token"} in fields
    refute {inspect(S.BooleanToken), ":token"} in fields

    for field <- [
          :public_refresh_token,
          :api_key_hash,
          :password,
          :unknown_secret,
          :custom_secret
        ] do
      assert {inspect(S.Values), inspect(field)} in fields
    end
  end

  test "hash-named credentials keep a redaction warning without asserting a reusable secret" do
    for field <- [":api_key_hash", ":hashed_password", ":access_token_digest"] do
      finding =
        Exposure.finding(:unredacted_secret, ["M", field, "credential", "unaware", "redact"])

      assert finding.severity == :warning
      assert finding.detail =~ "name suggests a hash or digest"
      assert finding.detail =~ "does not by itself establish"
      refute finding.detail =~ "If it stores a live credential"
    end

    raw =
      Exposure.finding(:unredacted_secret, ["M", ":api_key", "credential", "unaware", "redact"])

    assert raw.severity == :error
    assert raw.detail =~ "If it stores a live credential"
  end

  @tag :souffle
  test "test-support hash warnings step down without hiding raw credential findings" do
    assert {:ok, results} = Argus.Findings.run(@mods, analyses: [:exposure])
    assert results.degraded == []

    fields =
      for finding <- results.findings,
          finding.module == Argus.Test.Support.HashedSecret,
          into: %{},
          do: {finding.at_source, finding}

    assert fields[":api_key_hash"].severity == :info
    assert fields[":api_key"].severity == :warning
    assert Enum.any?(fields[":api_key_hash"].help, &String.contains?(&1, "test support"))
  end
end
