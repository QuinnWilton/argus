defmodule Argus.Schema.TermValidation do
  @moduledoc "Semantic validation of the exact decoded ETF result."

  @spec relations() :: [Argus.Schema.declaration()]
  def relations do
    Argus.Schema.Reads.record("relations #{__MODULE__}", [
      %{
        name: :decoded_term_validated,
        layer: 2,
        fields: [
          {:id, :symbol, "decoder instruction ID"},
          {:func, :symbol, "calling function ID"}
        ],
        doc: """
        Every accepted payload from this decoded term follows a successful local recursive \
        validator. Rejected error envelopes may be returned unchanged; projecting or \
        consuming their rejected payload is not certified. Validation accepts only \
        inert scalars and recursively checks list \
        heads/tails, every tuple element, and map keys/values. The proof follows exact \
        values and accepted verdicts, including exception handlers; unknown operations \
        establish no safety. This does not exclude compressed ETF allocation or make \
        decoding without safe immune to atom creation.
        """
      }
    ])
  end
end
