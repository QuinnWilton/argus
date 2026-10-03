defmodule Argus.Analyses.UnsafeInput.Verification do
  @moduledoc false

  alias Argus.Findings

  @spec output_relations() :: [Argus.Analysis.output_relation()]
  def output_relations do
    [
      %{
        name: :unchecked_crypto_verification,
        fields: [
          {:id, :symbol, "verification instruction ID"},
          {:func, :symbol, "function performing verification"},
          {:api, :symbol, "verification function ID"},
          {:use, :symbol, "payload use or verdict discard instruction ID"},
          {:kind, :symbol, "payload | discarded"}
        ],
        key: [:id],
        earliest: :use,
        doc:
          "A cryptographic verification verdict is not enforced before payload use or is discarded."
      }
    ]
  end

  @spec finding(atom(), [String.t()]) :: Findings.attrs()
  def finding(:unchecked_crypto_verification, [id, func, api, use, "payload"]) do
    Findings.new(
      :error,
      "Cryptographic verification result is not enforced",
      "#{func} uses a payload returned by #{api} without establishing that this " <>
        "invocation's verification boolean is true on every path to that use. " <>
        "JOSE returns the payload even when verification fails; matching the " <>
        "tuple's shape does not authenticate its contents.",
      at: Findings.at_instr(id),
      at_label: "verification returns a separate boolean verdict",
      related: [
        Findings.related("payload used without a proven true verdict", Findings.at_instr(use))
      ],
      help: [
        "match `{true, payload, signer}` before accepting the payload, and reject every other result",
        "if verification is delegated, preserve both the verdict and payload for the recipient to check"
      ]
    )
  end

  def finding(:unchecked_crypto_verification, [id, func, api, use, "discarded"]) do
    Findings.new(
      :error,
      "Cryptographic verification result is not enforced",
      "#{func} calls #{api} and discards its boolean result without reading it. " <>
        "A failed signature returns false; returning normally from verification " <>
        "does not establish that the signature is valid.",
      at: Findings.at_instr(id),
      at_label: "verification boolean is discarded",
      related: [Findings.related("last copy discarded here", Findings.at_instr(use))],
      help: ["require the result to be true before accepting the signed data; reject false"]
    )
  end
end
