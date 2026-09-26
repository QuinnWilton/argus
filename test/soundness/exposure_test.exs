defmodule Argus.Soundness.ExposureTest do
  @moduledoc """
  A server's `verify_none` is quiet only as its own TLS option, and only
  when it names nothing to check clients with (soundness review 2; the
  review's probes and their neighbours, test/fixtures/soundness/
  exposure_fixture.ex).
  """
  use ExUnit.Case, async: true

  import Argus.Test.Soundness.Case

  setup_all do
    unless Argus.Souffle.available?(), do: raise("souffle not installed")
    %{sev: severities(modules("exposure_fixture.ex"), [:exposure])}
  end

  @off "TLS certificate verification turned off"

  test "a client's options nested in a server's, and mTLS turned off, stay errors", %{sev: sev} do
    assert severity(sev, "G2.TlsProxyServer", :child_spec, @off) == :error
    assert severity(sev, "G2.TlsProxyServer", :relay_spec, @off) == :error
    assert severity(sev, "G2.TlsPeerListener", :listen, @off) == :error

    for fun <- [:proxy, :island, :fun_listener, :merged],
        do: assert(severity(sev, "Adv.Tls.Servers", fun, @off) == :error, "#{fun}")
  end

  test "a server asking its clients for nothing stays quiet", %{sev: sev} do
    for fun <- [:island, :bandit, :listener],
        do: assert(severity(sev, "Adv.Tls.Quiet", fun, "TLS") == nil, "#{fun}")
  end
end
