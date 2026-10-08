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
      },
      %{
        name: :decoded_bytes_value,
        layer: 2,
        fields: [
          {:id, :symbol, "decoding call, or a local call of a decoding function"},
          {:func, :symbol, "calling function ID"},
          {:pos, :number, "argument position: 0 at a decoder, the parameter's at a local call"},
          {:param, :number, "the caller's parameter the argument is, else -1"},
          {:callee, :symbol, "the remote callee whose result it is projected from, else empty"},
          {:path, :symbol, "the projection out of that result (tuple:1/map:key), else empty"}
        ],
        doc: """
        The argument is exactly this value on every path to the call: the caller's \
        parameter, or a field projected out of a remote call's result in the same \
        function. Rows are emitted at decoding calls, and at local calls of a function \
        whose decoder decodes its parameter, at that position. A join of different \
        values, a computed value, or a local helper's result has no row.
        """
      }
    ])
  end
end
