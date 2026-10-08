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

  # Every function each relation reports over the fixtures, exactly: a
  # case the analysis newly reports fails here as surely as one it drops.
  test "verify_none is reported where nothing else could be chosen, and only there" do
    assert funcs("disables_verification") == [
             # Forces :verify_none whenever it is asked for TLS.
             inspect(T.ForcesNone) <> ":opts/1",
             # A listener's options that leave the function (returned) or
             # also reach a connect are a client's too.
             inspect(T.ReturnsOptions) <> ":listen/2",
             inspect(T.ServesAndDials) <> ":start/3"
           ]

    # Not reported:
    #   * OffersChoice: naming :verify_peer anywhere means the caller can
    #     have a secure channel. The distinction the analysis exists for,
    #     and the one a search cannot make: Sequin's ConfigParser maps
    #     REDIS_TLS_VERIFY=verify-none onto :verify_none and also sets
    #     :verify_peer when certs are configured, a configuration
    #     surface; RedisStringSink forces :verify_none and offers nothing
    #     else.
    #   * Listener, Accepts: on a listener or an accepted socket,
    #     verify_none means the server asks its clients for no
    #     certificate (ejabberd's HTTP listener, supavisor's client
    #     handler).
    #   * Verifies: verifying properly is silent.
    #   * DynamicOpts: options built at runtime are not guessed at. A
    #     false "this is insecure" against code that configures itself
    #     properly is the finding that gets an analysis switched off.
  end

  test "literal options that never mention :verify are reported, a listener's not" do
    # Listener leaves :verify out too: a server is not left to a client's
    # default. Verifies and DynamicOpts are silent here as above.
    assert funcs("relies_on_default_verification") == [
             inspect(T.DefaultsSilently) <> ":connect/1"
           ]
  end
end
