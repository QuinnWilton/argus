defmodule Argus.Analyses.ExposureSecretsTest do
  use ExUnit.Case

  alias Argus.Souffle
  alias Argus.Test.Fixtures.Secret, as: S

  @all [S.Exposed, S.PartlyRedacted, S.Redacted, S.Ordinary]

  defp skip_without_souffle do
    unless Souffle.available?(), do: flunk("souffle not installed")
  end

  defp rows do
    assert {:ok, r} = Argus.analyze(@all, :exposure)
    Map.get(r, "unredacted_secret", [])
  end

  defp for_mod(fragment), do: Enum.filter(rows(), &String.contains?(hd(&1), fragment))

  test "an unredacted credential is reported" do
    skip_without_souffle()

    fields = for_mod("Secret.Exposed") |> Enum.map(fn [_m, f, _k, _a] -> f end) |> Enum.sort()
    assert fields == [":sendgrid_api_key", ":smtp_password"]
  end

  test "redacting discharges it" do
    skip_without_souffle()
    assert for_mod("Secret.Redacted") == []
  end

  test "a field name that suggests nothing is not reported" do
    skip_without_souffle()
    assert for_mod("Secret.Ordinary") == []
  end

  test "a schema that redacts something else is marked aware" do
    skip_without_souffle()

    # The stronger finding: the pattern is known in this module and was not
    # applied to this field, so it is an oversight rather than an unfamiliar
    # API — and the finding says so.
    assert [[_m, ":client_secret", "credential", "aware"]] = for_mod("PartlyRedacted")
  end

  test "severity separates a live third-party credential from a hash" do
    mod = Argus.Analyses.Exposure
    cred = mod.finding(:unredacted_secret, ["M", ":api_key", "credential", "unaware"])
    pass = mod.finding(:unredacted_secret, ["M", ":password", "password", "unaware"])

    assert cred.severity == :error
    assert cred.detail =~ "someone else's system"
    assert pass.severity == :warning
  end
end
