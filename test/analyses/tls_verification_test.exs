defmodule Argus.Analyses.TlsVerificationTest do
  use ExUnit.Case

  alias Argus.Souffle
  alias Argus.Test.Fixtures.Tls, as: T

  @all [T.ForcesNone, T.OffersChoice, T.Verifies, T.DefaultsSilently, T.DynamicOpts]

  defp skip_without_souffle do
    unless Souffle.available?(), do: flunk("souffle not installed")
  end

  defp funcs(relation) do
    assert {:ok, r} = Argus.analyze(@all, :tls_verification)
    r |> Map.get(relation, []) |> Enum.map(&hd/1) |> Enum.uniq() |> Enum.sort()
  end

  defp named?(list, fragment), do: Enum.any?(list, &String.contains?(&1, fragment))

  describe "detection" do
    test "a module that forces verify_none is reported" do
      skip_without_souffle()
      assert named?(funcs("disables_verification"), "ForcesNone")
    end

    test "literal options that never mention :verify are reported" do
      skip_without_souffle()
      assert named?(funcs("relies_on_default_verification"), "DefaultsSilently")
    end
  end

  describe "the claim is the absence of a choice, not the atom" do
    # The distinction the analysis exists for, and the one a search cannot
    # make. Sequin's ConfigParser maps REDIS_TLS_VERIFY=verify-none onto
    # :verify_none and also sets :verify_peer when certs are configured —
    # a configuration surface. RedisStringSink forces :verify_none whenever
    # tls: true and offers nothing else.
    test "a module offering verification too is not reported" do
      skip_without_souffle()
      names = funcs("disables_verification")

      assert named?(names, "ForcesNone")

      refute named?(names, "OffersChoice"),
             "naming :verify_peer anywhere means the caller can have a secure channel"
    end
  end

  describe "what is deliberately not reported" do
    test "verifying properly is silent" do
      skip_without_souffle()
      assert funcs("disables_verification") |> named?("Verifies") == false
      assert funcs("relies_on_default_verification") |> named?("Verifies") == false
    end

    test "options built at runtime are not guessed at" do
      skip_without_souffle()

      # A false "this is insecure" against code that configures itself
      # properly is the finding that gets an analysis switched off.
      refute named?(funcs("relies_on_default_verification"), "DynamicOpts")
      refute named?(funcs("disables_verification"), "DynamicOpts")
    end
  end
end
