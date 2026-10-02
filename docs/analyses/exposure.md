# Secret and TLS exposure

[Bug-class catalog](../bug-classes.md)

These checks identify secrets included in inspected structs and TLS options that
can leave peer verification disabled. They use specific source and bytecode patterns,
not a complete information-flow or TLS configuration model.

## Secrets printed by Inspect

`unredacted_secret` · **error** for credentials; **warning** for passwords, tokens and hash-named fields

An Ecto persisted field has a secret-like name and remains visible to Inspect.
Logging a struct, reporting an error or inspecting a changeset can disclose it.
The finding's `via` identifies whether to change field redaction or a derived
Inspect implementation.

When a schema derives Inspect, that implementation determines visible fields;
redact: true alone may not hide them. Without a visible derived implementation,
the analysis relies on the schema's redacted-field metadata.

Names are clues, not proof. Metadata suffixes and fields with a known boolean
schema type are excluded. String, custom and unknown types remain candidates;
identifiers such as api_key_id can still match. A hash-like name changes the
finding's severity and wording, but does not remove it: offline guessing risk
depends on the secret's entropy and the hash construction. Test-support findings
step down one severity level.

Virtual fields, plain structs, JSON encoders and hand-written Inspect
implementations are not fully covered. Review the actual value and output behaviour.

## Secrets identified by a prior

`unredacted_secret_inferred` · **warning** for credentials; **info** for passwords and tokens

With priors enabled, a classifier can identify an otherwise unmatched persisted
field as sensitive at confidence 0.9 or higher. The same Inspect visibility checks
apply, including the known-boolean exclusion. The finding is marked heuristic and
shows the inferred kind and confidence.
Priors are optional; structural name-based findings do not depend on them.

## Explicitly disabled TLS verification

`disables_verification` · **error**

A client connection's literal options disable peer verification, or a module mentions
verify_none without a recognized alternative verification setting. A client can then
accept an unauthenticated peer certificate. Configure verification appropriate to the
client's trust and hostname requirements.

Recognized server-only options are excluded: declining to request client certificates
is different from a client declining to verify its server. The fallback is broad and
can mistake an unrelated atom mention for configuration. Conversely, a verify_peer
mention elsewhere can hide some cases. Custom verification callbacks, hostname
checks and library-specific insecure flags are not established by this rule.

## Verification left to a default

`relies_on_default_verification` · **warning**

A supported client TLS call supplies a fully literal option list without verify.
The intended verification policy is implicit and can depend on the runtime or
library version. State that policy explicitly when portability matters.

This check does not inspect every TLS wrapper or overload, and dynamic option lists
are skipped. Server listen/handshake configuration is excluded where recognized.
The finding does not by itself prove that the runtime default is insecure.

## Implementation

[Rules](https://github.com/QuinnWilton/argus/blob/main/priv/dl/analyses/exposure.dl) · [Output schema and finding builder](https://github.com/QuinnWilton/argus/blob/main/lib/argus/analyses/exposure.ex).
