defmodule Argus.Analyses.Exposure do
  @moduledoc """
  Credentials printed, or sent unauthenticated.

  - `unredacted_secret(mod, field, kind, aware, via, anchor)` — an Ecto schema
    field that looks like a credential, password or token and that
    `inspect/1` prints in full — neither `redact: true` nor left out of
    the struct's `@derive {Inspect, ...}` — into Logger calls, changeset
    errors, LiveView debug output, crash reports, and any error reporter
    that serialises state. `aware` says whether the schema hides some
    other field, which makes the omission an oversight rather than an
    unfamiliar API; `via` says where the fix goes, `redact` or the
    schema's own `derive` (which makes `redact: true` a no-op).
  - `unredacted_secret_inferred(mod, field, kind, aware, via, permille, anchor)`
    — the same finding for a field the sensitivity prior names a secret
    and no name fragment does: a step down in severity, heuristic, with
    the prior's probability.
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
  def extractors,
    do: [
      Argus.Extractors.EctoSchema,
      Argus.Extractors.DerivedInspect,
      Argus.Extractors.Tls,
      Argus.Extractors.Tooling
    ]

  @impl true
  def output_relations do
    [
      %{
        name: :unredacted_secret,
        fields: [
          {:mod, :symbol, "the schema"},
          {:field, :symbol, "the field"},
          {:kind, :symbol, "credential | password | token"},
          {:aware, :symbol, "whether the schema hides anything else from inspect/1"},
          {:via, :symbol, "redact | derive — where the schema hides fields"},
          {:anchor, :symbol,
           "the schema the finding points at: the field's own, or, for an embed compiled with no line, the one embedding it"}
        ],
        key: [:mod, :field],
        doc: "A secret-looking field that inspect/1 will print in full."
      },
      %{
        name: :unredacted_secret_inferred,
        fields: [
          {:mod, :symbol, "the schema"},
          {:field, :symbol, "the field"},
          {:kind, :symbol, "credential | password | token"},
          {:aware, :symbol, "whether the schema hides anything else from inspect/1"},
          {:via, :symbol, "redact | derive — where the schema hides fields"},
          {:permille, :number,
           "the classifier's probability that the field is a secret of any kind, in thousandths"},
          {:anchor, :symbol, "as unredacted_secret's"}
        ],
        key: [:mod, :field],
        doc:
          "A field the substring table does not name but a classifier does " <>
            "(Argus.Priors, at 0.9 and above); heuristic, reported a step below the structural finding."
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
      },
      Argus.Findings.Tooling.relation()
    ]
  end

  @impl true
  def finding(:unredacted_secret, [mod, field, kind, aware, via]),
    do: finding(:unredacted_secret, [mod, field, kind, aware, via, mod])

  def finding(:unredacted_secret, [mod, field, kind, aware, via, anchor]) do
    Findings.new(
      severity(kind, field),
      # The field as a reader writes its access, `User.password_hash`;
      # the facts spell the key as an atom, `:password_hash`.
      "Secret field printed by inspect/1",
      why_printed(via, mod, field) <>
        ", so it appears in full wherever " <>
        "the struct is inspected — Logger calls, changeset errors, LiveView " <>
        "debug output, crash reports, and any error reporter that serialises " <>
        "state. " <>
        Enum.join(
          Enum.reject([consequence(kind, field), awareness(aware, mod)], &(&1 == "")),
          " "
        ),
      # Bytecode places every generated schema function at the `schema do`
      # line; the field's own line is in the source, under its name. An
      # `embeds_one ... do` block's module has no line: the schema that
      # embeds it is where the block is.
      at: Findings.at_mfa(anchor, :__schema__, 1),
      at_source: field,
      at_label: at_label(via, String.trim_leading(field, ":")),
      help: [fix(via, field)]
    )
  end

  # The same finding as the structural one, made heuristic: a step down
  # in severity, and a help line with the probability — the reader knows
  # a model, not a substring, named the field.
  def finding(:unredacted_secret_inferred, [mod, field, kind, aware, via, permille]),
    do: finding(:unredacted_secret_inferred, [mod, field, kind, aware, via, permille, mod])

  def finding(:unredacted_secret_inferred, [mod, field, kind, aware, via, permille, anchor]) do
    Findings.heuristic(
      finding(:unredacted_secret, [mod, field, kind, aware, via, anchor]),
      String.to_integer(permille),
      "a classifier names #{field} a secret, most likely a #{kind}"
    )
  end

  def finding(:disables_verification, [func, id]) do
    Findings.new(
      :error,
      "TLS certificate verification turned off",
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
        "get one.",
      at: Findings.at_instr(id),
      at_label: "verify: :verify_none",
      help: [
        "use `verify: :verify_peer` with cacerts, from :public_key.cacerts_get/0 " <>
          "or the castore package"
      ]
    )
  end

  def finding(:relies_on_default_verification, [func, id, api]) do
    Findings.new(
      :warning,
      "TLS verification left to the library default",
      "#{func} calls #{api} with a literal option list that never mentions " <>
        ":verify, so whatever the library defaults to applies. Erlang's :ssl " <>
        "client verified nothing at all before OTP 26, and wrappers that pass " <>
        "options straight through inherit that. " <>
        "Unlike an explicit :verify_none this was probably not a decision, " <>
        "which is precisely why it survives review: there is nothing at the " <>
        "call site to notice.",
      at: Findings.at_instr(id),
      at_label: "no :verify option here",
      help: [
        "set :verify explicitly (`verify: :verify_peer` with cacerts), so the " <>
          "connection's security is stated in the code rather than inherited " <>
          "from the OTP version it runs on"
      ]
    )
  end

  defp severity("credential", field), do: if(hash_named?(field), do: :warning, else: :error)
  defp severity(_other, _field), do: :warning

  defp consequence(kind, field) do
    if hash_named?(field) do
      "The field name suggests a hash or digest, rather than a raw credential. " <>
        "Exposure may permit offline guessing, depending on the original secret's " <>
        "entropy and the hash construction; it does not by itself establish a " <>
        "reusable password or bearer token."
    else
      raw_consequence(kind)
    end
  end

  defp raw_consequence("credential") do
    "The field name suggests credential material. If it stores a live credential, " <>
      "exposing it can grant access to the system that accepts it until it is revoked."
  end

  defp raw_consequence("password") do
    "The field name suggests a password. A plaintext value can authenticate directly; " <>
      "a stored password hash can permit offline guessing. The name alone does not " <>
      "establish which representation is stored."
  end

  defp raw_consequence("token"),
    do:
      "If the field stores a raw bearer token, exposure permits its use until expiry or revocation."

  defp raw_consequence(_other), do: ""

  defp hash_named?(field),
    do: Regex.match?(~r/(?:^:?(?:hashed_|hash_|digest_)|_(?:hash|digest)$)/, field)

  defp why_printed("derive", mod, field),
    do: "#{mod} derives Inspect with a field list that keeps #{field}"

  defp why_printed(_redact, _mod, field), do: "#{field} is not declared redact: true"

  defp at_label("derive", name), do: "#{name} kept by the schema's derived Inspect"
  defp at_label(_redact, name), do: "#{name} declared without redact: true"

  # Ecto derives Inspect for its redacted fields only when the schema
  # derives none itself, so under a schema's own derive `redact: true`
  # changes nothing.
  defp fix("derive", field) do
    "leave #{field} out of the schema's `@derive {Inspect, ...}` — add it to " <>
      "`except:`, or drop it from `only:`; `redact: true` has no effect on a " <>
      "schema that derives Inspect itself"
  end

  defp fix(_redact, _field), do: "add `redact: true` to the field"

  defp awareness("aware", mod) do
    "#{mod} hides some other field from inspect/1, so the pattern is already known here " <>
      "and was not applied to this one — which makes this an oversight rather " <>
      "than an unfamiliar API."
  end

  defp awareness(_unaware, _mod), do: ""
end
