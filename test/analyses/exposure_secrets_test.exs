defmodule Argus.Analyses.ExposureSecretsTest do
  use ExUnit.Case, async: true

  alias Argus.Analyses.Exposure
  alias Argus.Souffle
  alias Argus.Test.Fixtures.Secret, as: S
  alias Argus.Test.Memo

  @derived [S.DerivedExcept, S.DerivedOnly, S.LeakyOnly, S.EctoDerived, S.RedactOverridden]

  # A derived Inspect lives in its own module, Inspect.<Struct>, which a
  # run over a project's beams includes.
  @all [S.Exposed, S.PartlyRedacted, S.Redacted, S.Ordinary, S.SecretMetadata] ++
         @derived ++ Enum.map(@derived, &Module.concat(Inspect, &1))

  defp skip_without_souffle do
    unless Souffle.available?(), do: flunk("souffle not installed")
  end

  defp rows do
    assert {:ok, r} = Memo.analyze(@all, :exposure)
    Map.get(r, "unredacted_secret", [])
  end

  defp for_mod(fragment), do: Enum.filter(rows(), &String.contains?(hd(&1), fragment))

  test "an unredacted credential is reported" do
    skip_without_souffle()

    fields = for_mod("Secret.Exposed") |> Enum.map(&Enum.at(&1, 1)) |> Enum.sort()
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

  test "a field that holds a fact about a secret is not the secret" do
    skip_without_souffle()
    fields = Enum.map(for_mod("Secret.SecretMetadata"), &Enum.at(&1, 1))
    assert fields == [":access_token"]
  end

  test "a schema that redacts something else is marked aware" do
    skip_without_souffle()

    # The stronger finding: the pattern is known in this module and was not
    # applied to this field, so it is an oversight rather than an unfamiliar
    # API — and the finding says so.
    assert [[_m, ":client_secret", "credential", "aware", "redact"]] = for_mod("PartlyRedacted")
  end

  test "severity separates a live third-party credential from a hash" do
    mod = Exposure
    cred = mod.finding(:unredacted_secret, ["M", ":api_key", "credential", "unaware", "redact"])
    pass = mod.finding(:unredacted_secret, ["M", ":password", "password", "unaware", "redact"])

    assert cred.severity == :error
    assert cred.detail =~ "someone else's system"
    assert pass.severity == :warning
  end

  test "the anchor is the schema's generated function, refined by the field's name" do
    finding =
      Exposure.finding(:unredacted_secret, [
        "Argus.Test.Fixtures.Secret.Exposed",
        ":smtp_password",
        "password",
        "unaware",
        "redact"
      ])

    assert finding.mfa == {Argus.Test.Fixtures.Secret.Exposed, :__schema__, 1}
    assert finding.at_source == ":smtp_password"
    assert finding.at_label == "smtp_password declared without redact: true"
  end

  describe "a derived Inspect" do
    test "except: hides the fields it lists and prints the one it forgot" do
      skip_without_souffle()

      # :password and :jwt are excluded; :sendgrid_api_key is not, and the
      # place to fix it is the derive, where redact: true would do nothing.
      assert [[_m, ":sendgrid_api_key", "credential", "aware", "derive"]] =
               for_mod("Secret.DerivedExcept")
    end

    test "only: prints what it names and nothing else" do
      skip_without_souffle()

      assert for_mod("Secret.DerivedOnly") == []

      assert [[_m, ":api_key", "credential", "aware", "derive"]] =
               for_mod("Secret.LeakyOnly")
    end

    test "Ecto's own derive for redact: true leaves the fix at redact: true" do
      skip_without_souffle()

      assert [[_m, ":api_key", "credential", "aware", "redact"]] = for_mod("Secret.EctoDerived")
    end

    test "redact: true under the schema's own derive hides nothing" do
      skip_without_souffle()

      assert [[_m, ":password", "password", "unaware", "derive"]] =
               for_mod("Secret.RedactOverridden")
    end

    test "without the impl module in view, redact: true is taken at its word" do
      skip_without_souffle()

      assert {:ok, r} = Memo.analyze([S.RedactOverridden], :exposure)
      assert Map.get(r, "unredacted_secret", []) == []
    end

    test "the finding sends the fix to the derive" do
      finding =
        Exposure.finding(:unredacted_secret, [
          "M",
          ":api_key",
          "credential",
          "aware",
          "derive"
        ])

      assert finding.detail =~ "M derives Inspect with a field list that keeps :api_key"
      assert finding.at_label == "api_key kept by the schema's derived Inspect"
      assert [help] = finding.help
      assert help =~ "except:"
    end
  end
end
