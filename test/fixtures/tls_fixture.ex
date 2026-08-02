defmodule Argus.Test.Fixtures.Tls do
  @moduledoc """
  Fixtures for the TLS-verification analysis.

  The pair that carries the claim is `ForcesNone` against `OffersChoice`:
  both name `:verify_none`, and only one of them denies the caller any way
  to get a verified connection.
  """

  defmodule ForcesNone do
    @moduledoc "The bug: TLS on means verification off, with no alternative."
    def opts(%{tls: true}), do: Keyword.put([], :ssl, verify: :verify_none)
    def opts(_), do: []
  end

  defmodule OffersChoice do
    @moduledoc """
    Names :verify_none too, but supports verification — so the caller can
    have a secure channel and this is a configuration surface, not a bug.
    """
    def opts(%{verify: :none}), do: [verify: :verify_none]
    def opts(_), do: [verify: :verify_peer, cacerts: []]
  end

  defmodule Verifies do
    @moduledoc "Never mentions :verify_none at all."
    def connect(host), do: :ssl.connect(host, 443, [verify: :verify_peer], 5000)
  end

  defmodule DefaultsSilently do
    @moduledoc "Literal options that never mention :verify."
    def connect(host), do: :ssl.connect(host, 443, [active: false], 5000)
  end

  defmodule DynamicOpts do
    @moduledoc "Options built at runtime — unknowable, so unreported."
    def connect(host, opts), do: :ssl.connect(host, 443, opts, 5000)
  end
end
