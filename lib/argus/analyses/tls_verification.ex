defmodule Argus.Analyses.TlsVerification do
  @moduledoc """
  TLS that encrypts without authenticating.

  A TLS connection that does not verify the peer's certificate is
  confidential against a passive observer and wide open to anyone who can
  answer for the host — which is the threat TLS exists to address. Nothing
  distinguishes a verified session from an unverified one at runtime: the
  connection succeeds, the bytes are encrypted, and the padlock is a lie.

  Two shapes, and the second is why this is an analysis rather than a
  search. `verify: :verify_none` is a literal someone wrote and can be
  grepped. An option list that never mentions `verify` at all takes whatever
  the library defaults to — and Erlang's `:ssl` client verified nothing
  before OTP 26. Reading that call site tells you nothing, because the
  absence is the finding, and absence is what a search cannot look for.
  """

  @behaviour Argus.Analysis

  alias Argus.Findings

  @impl true
  def name, do: :tls_verification

  @impl true
  def description, do: "TLS connections that do not verify the peer"

  @impl true
  def rules_file, do: "analyses/tls_verification.dl"

  @impl true
  def extractors, do: [Argus.Extractors.Tls]

  @impl true
  def output_relations do
    [
      %{
        name: :disables_verification,
        fields: [
          {:func, :symbol, "the function"},
          {:id, :symbol, "the site"}
        ],
        key: [:func],
        doc: "verify: :verify_none — peer certificates are not checked."
      },
      %{
        name: :relies_on_default_verification,
        fields: [
          {:func, :symbol, "the function"},
          {:id, :symbol, "the site"},
          {:api, :symbol, "the connect API"}
        ],
        key: [:func, :api],
        doc: "A TLS connect whose literal options never mention :verify."
      }
    ]
  end

  @impl true
  def finding(:disables_verification, [func, id]) do
    Findings.new(
      :error,
      "#{func} turns off TLS certificate verification",
      "#{func} sets verify: :verify_none, so the peer's certificate is not " <>
        "checked against any trust anchor and its hostname is not matched. " <>
        "The connection is still encrypted, which is what makes this quiet: " <>
        "anyone able to answer for the host — DNS, ARP, a proxy, a compromised " <>
        "network — terminates the session with a certificate they minted " <>
        "themselves, and both ends report success. " <>
        "Encryption without authentication is not security; it is the same " <>
        "guarantee as an unencrypted connection to an unknown party. " <>
        "Worth checking who chose this: when the surrounding code enables TLS " <>
        "on the user's behalf, the user asked for a secure channel and did not " <>
        "get one. " <>
        "Use verify: :verify_peer with cacerts, from :public_key.cacerts_get/0 " <>
        "or the castore package.",
      at: Findings.at_instr(id)
    )
  end

  def finding(:relies_on_default_verification, [func, id, api]) do
    Findings.new(
      :warning,
      "#{func} leaves TLS verification to the default",
      "#{func} calls #{api} with a literal option list that never mentions " <>
        ":verify, so whatever the library defaults to applies. Erlang's :ssl " <>
        "client verified nothing at all before OTP 26, and wrappers that pass " <>
        "options straight through inherit that. " <>
        "Unlike an explicit :verify_none this was probably not a decision, " <>
        "which is precisely why it survives review: there is nothing at the " <>
        "call site to notice. " <>
        "Set :verify explicitly, so that the security of the connection is " <>
        "stated in the code rather than inherited from the OTP version it " <>
        "happens to run on.",
      at: Findings.at_instr(id)
    )
  end
end
