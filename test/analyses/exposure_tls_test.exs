defmodule Argus.Analyses.ExposureTlsTest do
  use ExUnit.Case, async: true
  @moduletag :flowlog

  alias Argus.Test.Fixtures.Tls, as: T
  alias Argus.Test.Memo

  @all [
    T.ForcesNone,
    T.OffersChoice,
    T.Verifies,
    T.DefaultsSilently,
    T.DynamicOpts,
    T.Listener,
    T.Accepts,
    T.ServesAndDials,
    T.ReturnsOptions
  ]

  defp funcs(relation) do
    assert {:ok, r} = Memo.analyze(@all, :exposure)
    r |> Map.get(relation, []) |> Enum.map(&hd/1) |> Enum.uniq() |> Enum.sort()
  end

  defp named?(list, fragment), do: Enum.any?(list, &String.contains?(&1, fragment))

  describe "detection" do
    test "a module that forces verify_none is reported" do
      assert named?(funcs("disables_verification"), "ForcesNone")
    end

    test "literal options that never mention :verify are reported" do
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
      names = funcs("disables_verification")

      assert named?(names, "ForcesNone")

      refute named?(names, "OffersChoice"),
             "naming :verify_peer anywhere means the caller can have a secure channel"
    end
  end

  describe "a server's side" do
    # On a listener or an accepted socket, verify_none means the server
    # asks its clients for no certificate: ejabberd's HTTP listener,
    # supavisor's client handler.
    test "a listener's or an accepted socket's verify_none is not reported" do
      names = funcs("disables_verification")

      refute named?(names, "Listener")
      refute named?(names, "Accepts")
    end

    test "a listener that leaves verify out is not left to a client's default" do
      names = funcs("relies_on_default_verification")

      refute named?(names, "Listener")
      assert named?(names, "DefaultsSilently")
    end

    test "options that also reach a connect, or leave the function, are reported" do
      names = funcs("disables_verification")

      assert named?(names, "ServesAndDials")
      assert named?(names, "ReturnsOptions")
    end
  end

  describe "what is deliberately not reported" do
    test "verifying properly is silent" do
      assert funcs("disables_verification") |> named?("Verifies") == false
      assert funcs("relies_on_default_verification") |> named?("Verifies") == false
    end

    test "options built at runtime are not guessed at" do
      # A false "this is insecure" against code that configures itself
      # properly is the finding that gets an analysis switched off.
      refute named?(funcs("relies_on_default_verification"), "DynamicOpts")
      refute named?(funcs("disables_verification"), "DynamicOpts")
    end
  end
end
