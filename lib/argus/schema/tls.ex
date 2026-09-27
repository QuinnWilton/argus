defmodule Argus.Schema.Tls do
  @moduledoc """
  TLS connections and how their peers are verified.

  Layer 2 of `Argus.Schema`, which reads the relations from here.
  """

  @doc "The relations, in the order `Argus.Schema.all/0` lists them."
  @spec relations() :: [Argus.Schema.declaration()]
  def relations do
    Argus.Schema.Reads.record("relations #{__MODULE__}", [
      %{
        name: :tls_verification,
        layer: 2,
        fields: [
          {:id, :symbol, "the instruction"},
          {:func, :symbol, "the function"},
          {:setting, :symbol, "'none' | 'peer' | 'absent'"}
        ],
        doc: """
        How a TLS session verifies its peer, read from literal option lists and \
        bare atoms. `absent` means a connect supplied literal options that never \
        mention `verify`, so the library's default applies — Erlang's `:ssl` \
        client verified nothing at all before OTP 26.
        """
      },
      %{
        name: :tls_connect,
        layer: 2,
        fields: [
          {:id, :symbol, "the instruction"},
          {:func, :symbol, "the calling function"},
          {:api, :symbol, "the connect API"},
          {:opts, :symbol, "how options were supplied: 'literal' | 'dynamic'"}
        ],
        doc: """
        A call establishing a TLS session. `dynamic` options are recorded as \
        such rather than guessed at: a false "this is insecure" on a call that \
        configures itself properly is worse than silence.
        """
      },
      %{
        name: :tls_server_side,
        layer: 2,
        fields: [
          {:id, :symbol, "the instruction"},
          {:func, :symbol, "the function"}
        ],
        doc: """
        A verification setting that configures a server: the site of a \
        server's call (`:ssl.listen/2`, `:ssl.handshake/2,3`, a Ranch or \
        Cowboy TLS listener, a Plug.Cowboy, Bandit or ThousandIsland server), \
        or a mention whose value is made, in its function, only into the \
        options of one. There `verify_none` means the server does not ask \
        its clients for a certificate, not that it trusts a peer server.
        """
      }
    ])
  end
end
