defmodule Argus.Analyses.Exposure do
  @moduledoc """
  Credentials printed, or sent unauthenticated.

  - `unredacted_secret(mod, field, kind, aware)` — an Ecto schema field
    that looks like a credential, password or token and is not declared
    `redact: true`, so `inspect/1` prints it in full: Logger calls,
    changeset errors, LiveView debug output, crash reports, and any
    error reporter that serialises state. `aware` says whether the
    schema redacts some other field, which makes the omission an
    oversight rather than an unfamiliar API.
  - `disables_verification(func, id)` — `verify: :verify_none`: the
    peer's certificate is not checked against any trust anchor and its
    hostname is not matched. Encryption without authentication is the
    same guarantee as an unencrypted connection to an unknown party.
  - `relies_on_default_verification(func, id, api)` — a TLS connect whose
    literal options never mention `:verify`, so whatever the library
    defaults to applies; Erlang's `:ssl` client verified nothing before
    OTP 26.
  """

  @behaviour Argus.Analysis

  alias Argus.Findings

  @impl true
  def name, do: :exposure

  @impl true
  def description, do: "secrets that inspect/1 prints, and TLS that does not verify the peer"

  @impl true
  def rules_file, do: "analyses/exposure.dl"

  @impl true
  def extractors, do: [Argus.Extractors.EctoSchema, Argus.Extractors.Tls]

  @impl true
  def output_relations do
    [
      %{
        name: :unredacted_secret,
        fields: [
          {:mod, :symbol, "the schema"},
          {:field, :symbol, "the field"},
          {:kind, :symbol, "credential | password | token"},
          {:aware, :symbol, "whether the schema redacts anything else"}
        ],
        key: [:mod, :field],
        doc: "A secret-looking field that inspect/1 will print in full."
      },
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
  def finding(:unredacted_secret, [mod, field, kind, aware]) do
    Findings.new(
      severity(kind),
      "#{mod}.#{field} is printed by inspect/1",
      "#{field} is not declared redact: true, so it appears in full wherever " <>
        "the struct is inspected — Logger calls, changeset errors, LiveView " <>
        "debug output, crash reports, and any error reporter that serialises " <>
        "state. " <>
        consequence(kind) <>
        " " <>
        awareness(aware, mod) <>
        " Add redact: true to the field.",
      at: Findings.at_module(mod)
    )
  end

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

  defp severity("credential"), do: :error
  defp severity(_other), do: :warning

  defp consequence("credential") do
    "This looks like a third-party credential, so leaking it hands over " <>
      "someone else's system rather than this one — the value is live until " <>
      "a human notices and rotates it."
  end

  defp consequence("password") do
    "A hash is not a plaintext password, but it is offline-attackable and " <>
      "does not belong in a log."
  end

  defp consequence("token"), do: "Bearer material, usable until it expires."
  defp consequence(_other), do: ""

  defp awareness("aware", mod) do
    "#{mod} redacts some other field, so the pattern is already known here " <>
      "and was not applied to this one — which makes this an oversight rather " <>
      "than an unfamiliar API."
  end

  defp awareness(_unaware, _mod), do: ""
end
