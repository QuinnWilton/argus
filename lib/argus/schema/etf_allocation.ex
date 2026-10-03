defmodule Argus.Schema.EtfAllocation do
  @moduledoc "ETF decoder calls and proofs excluding the compressed input format."

  @doc "The relations, in the order Argus.Schema.all/0 lists them."
  @spec relations() :: [Argus.Schema.declaration()]
  def relations do
    Argus.Schema.Reads.record("relations #{__MODULE__}", [
      %{
        name: :etf_decode_site,
        layer: 2,
        fields: [
          {:id, :symbol, "decoder call instruction ID"},
          {:func, :symbol, "calling function ID"},
          {:api, :symbol, "ETF decoding API, through a transparent local delegate when present"}
        ],
        doc: """
        A call that decodes ETF bytes from argument zero. Includes binary_to_term, \
        executable-term rejecting wrappers, and transparent same-module delegates. \
        A private delegate with local callers is represented at its callers, \
        preserving their argument guards. Exported delegates retain their independent \
        external-input finding. Options such as safe do not prevent allocation.
        """
      },
      %{
        name: :etf_compression_rejected,
        layer: 2,
        fields: [
          {:id, :symbol, "decoder call instruction ID"},
          {:func, :symbol, "calling function ID"}
        ],
        doc: """
        Every path reaching this call excludes ETF's 131,80 compressed prefix for \
        the exact bytes decoded. A local predicate's accepted result may establish \
        the exclusion when compressed input cannot return that result. Binary match \
        contexts require a known restored zero position to retain byte identity. \
        Byte-size caps and decoded-term shape checks alone do not establish this.
        """
      }
    ])
  end
end
