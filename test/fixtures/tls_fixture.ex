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

  defmodule Listener do
    @moduledoc """
    A server: `verify_none` on its listener means it asks its clients for
    no certificate, and a listener that leaves `verify` out does the same.
    """
    def listen(port, certfile),
      do: :ssl.listen(port, certfile: certfile, verify: :verify_none, active: false)

    def listen_default(port), do: :ssl.listen(port, active: false)
  end

  defmodule Accepts do
    @moduledoc """
    supavisor's client handler: options built at runtime for the server's
    handshake on an accepted socket.
    """
    def upgrade(sock, certs_keys) do
      opts = [verify: :verify_none, certs_keys: certs_keys]
      :ok = :inet.setopts(sock, active: false)
      :ssl.handshake(sock, opts, 5000)
    end
  end

  defmodule ServesAndDials do
    @moduledoc "One option list for a listener and a client's connect: the client does not verify."
    def start(port, host, certfile) do
      opts = [verify: :verify_none, certfile: certfile]
      {:ok, listener} = :ssl.listen(port, opts)
      {:ok, conn} = :ssl.connect(host, 443, opts, 5000)
      {listener, conn}
    end
  end

  defmodule ReturnsOptions do
    @moduledoc "Returns the options it listens with: where else they go is not seen."
    def listen(port, certfile) do
      opts = [verify: :verify_none, certfile: certfile]
      {:ok, listener} = :ssl.listen(port, opts)
      {listener, opts}
    end
  end
end
