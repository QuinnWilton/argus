# Soundness fixtures (review 2): each shape must keep the severity its
# test states. Probes of the review and adversarial neighbours.
# credo:disable-for-this-file
defmodule Argus.Test.Soundness.G2.TlsProxyServer do
  # A reverse proxy. Bandit serves it (the server's side), but the
  # plug's own init options carry the TLS options the plug DIALS its
  # upstream with: `verify: :verify_none` there is a client that trusts
  # whatever answers at billing.internal — a MITM on the upstream hop.
  # The mention is made only into Bandit.child_spec/1's options (nested
  # under `plug:`), so tls_server_side's walk takes it for the server's.
  def child_spec(port) do
    Bandit.child_spec(
      plug:
        {Argus.Test.Soundness.G2.TlsProxyPlug,
         upstream: ~c"billing.internal", ssl: [verify: :verify_none, versions: [:"tlsv1.3"]]},
      port: port
    )
  end

  # The same with ThousandIsland: a relay handler's options.
  def relay_spec(port) do
    ThousandIsland.child_spec(
      port: port,
      handler_module: Argus.Test.Soundness.G2.TlsProxyPlug,
      handler_options: [upstream_tls: [verify: :verify_none]]
    )
  end
end

defmodule Argus.Test.Soundness.G2.TlsProxyPlug do
  def init(opts), do: opts

  def call(conn, opts) do
    {:ok, sock} =
      :ssl.connect(Keyword.fetch!(opts, :upstream), 443, Keyword.fetch!(opts, :ssl), 5000)

    {conn, sock}
  end
end

defmodule Argus.Test.Soundness.G2.TlsPeerListener do
  # A cluster peer listener that authenticates its peers by client
  # certificate: it loads the peers' CA (cacertfile), but
  # `verify: :verify_none` means the server never asks for, let alone
  # checks, a client certificate against that CA — any client is
  # accepted as a peer. The client CA says client authentication was
  # intended. (fail_if_no_peer_cert is left out: OTP refuses it beside
  # verify_none.)
  def listen(port, dir) do
    :ssl.listen(port,
      certfile: Path.join(dir, "node.pem"),
      keyfile: Path.join(dir, "node.key"),
      cacertfile: Path.join(dir, "peers-ca.pem"),
      verify: :verify_none,
      active: false
    )
  end
end

defmodule Argus.Test.Soundness.Adv.Tls.Servers do
  # (a) The plug's upstream options, through a variable.
  def proxy(port) do
    upstream = [verify: :verify_none]
    Bandit.child_spec(plug: {Argus.Test.Soundness.Adv.Tls.Plug, ssl: upstream}, port: port)
  end

  # (b) mTLS meant: the clients' CA under transport_options, and verify_none.
  def island(port, dir) do
    ThousandIsland.child_spec(
      port: port,
      handler_module: Argus.Test.Soundness.Adv.Tls.Plug,
      transport_options: [cacertfile: Path.join(dir, "ca.pem"), verify: :verify_none]
    )
  end

  # (c) A verify_fun beside verify_none.
  def fun_listener(port), do: :ssl.listen(port, verify: :verify_none, verify_fun: {&check/3, nil})

  def check(_cert, _event, state), do: {:valid, state}

  # (d) Built with Keyword.merge: the clients' CA and verify_none.
  def merged(port, base, cas),
    do: :ssl.listen(port, Keyword.merge(base, cacerts: cas, verify: :verify_none))
end

defmodule Argus.Test.Soundness.Adv.Tls.Quiet do
  # A server asking its clients for nothing, three ways.
  def island(port, dir) do
    ThousandIsland.child_spec(
      port: port,
      handler_module: Argus.Test.Soundness.Adv.Tls.Plug,
      transport_options: [certfile: Path.join(dir, "c.pem"), verify: :verify_none]
    )
  end

  def bandit(port),
    do:
      Bandit.child_spec(
        plug: Argus.Test.Soundness.Adv.Tls.Plug,
        port: port,
        thousand_island_options: [transport_options: [verify: :verify_none]]
      )

  def listener(port, dir),
    do: :ssl.listen(port, certfile: Path.join(dir, "c.pem"), verify: :verify_none)
end

defmodule Argus.Test.Soundness.Adv.Tls.Plug do
  def init(o), do: o
  def call(conn, _o), do: conn
end
