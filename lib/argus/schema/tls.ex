defmodule Argus.Schema.Tls do
  @moduledoc """
  Layer-2 TLS connection and peer-verification facts. Exposed through `Argus.Schema`.
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
        TLS peer-verification mode from literal options or bare atoms. `absent` means \
        known options omit `verify`, so the library default applies. Erlang `:ssl` \
        clients before OTP 26 defaulted to no verification.
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
        A TLS connection call. Unresolved options remain `dynamic` and do not establish \
        insecure configuration.
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
        A verification setting used only for a TLS server, including listener or \
        handshake calls and options flowing exclusively to them. Here `verify_none` \
        disables client-certificate requests; it does not describe verification of a \
        remote server.
        """
      }
    ])
  end
end
