defmodule Argus.Test.Soundness.Census.Exposure do
  @moduledoc """
  The exclusion census's exposure hole (docs/design/exclusions.md,
  "Soundness surprises") and its adversarial neighbours: a module that
  names :verify_peer anywhere was credited with offering the choice, and
  its hard-coded :verify_none connects went unreported. Asserted by
  test/soundness/exposure_test.exs.
  """
end

defmodule Argus.Test.Soundness.Census.Exposure.MeshTransport do
  @moduledoc """
  The census program: every node listens with mutual TLS and dials its
  peers; the dialer verifies nothing, with no option to change it.
  """
  def listen(port) do
    :ssl.listen(port, [
      :binary,
      verify: :verify_peer,
      fail_if_no_peer_cert: true,
      cacertfile: ~c"priv/ca.pem",
      certfile: ~c"priv/node.pem",
      keyfile: ~c"priv/node.key",
      active: false
    ])
  end

  def dial(host, port),
    do: :ssl.connect(host, port, [:binary, verify: :verify_none, active: false])
end

defmodule Argus.Test.Soundness.Census.Exposure.TelemetryPush do
  @moduledoc "Two clients: the API connection verifies, the metrics push is forced unverified."
  def connect_api(host) do
    :ssl.connect(host, 443, [
      :binary,
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      active: false
    ])
  end

  def connect_metrics(host),
    do: :ssl.connect(host, 8443, [:binary, verify: :verify_none, active: false])
end

defmodule Argus.Test.Soundness.Census.Exposure.BoundOptions do
  @moduledoc "The unverified options bound first, then handed to the connect."
  def connect_api(host),
    do: :ssl.connect(host, 443, verify: :verify_peer, cacerts: :public_key.cacerts_get())

  def connect_backup(host) do
    opts = [:binary, verify: :verify_none]
    :ssl.connect(host, 8443, opts)
  end
end

defmodule Argus.Test.Soundness.Census.Exposure.Configurable do
  @moduledoc """
  Quiet: one connect whose verification its caller chooses, :verify_peer
  or :verify_none: the choice the module offers.
  """
  def connect(host, verify?) do
    opts =
      if verify?,
        do: [verify: :verify_peer, cacerts: :public_key.cacerts_get()],
        else: [verify: :verify_none]

    :ssl.connect(host, 443, [:binary | opts])
  end
end
