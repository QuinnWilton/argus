defmodule Argus.Schema.ResultChecks do
  @moduledoc "Call-result identity, consumption and checks before consumption."

  @doc "The relations, in the order `Argus.Schema.all/0` lists them."
  @spec relations() :: [Argus.Schema.declaration()]
  def relations do
    Argus.Schema.Reads.record("relations #{__MODULE__}", [
      %{
        name: :security_result,
        layer: 2,
        fields: [
          {:id, :symbol, "producing call instruction ID"},
          {:func, :symbol, "owning function ID"},
          {:callee, :symbol, "called function ID"}
        ],
        doc: "A call with a statically known target, retaining its invocation identity."
      },
      %{
        name: :security_result_use,
        layer: 2,
        fields: [
          {:id, :symbol, "producing call instruction ID"},
          {:func, :symbol, "owning function ID"},
          {:use, :symbol, "consuming instruction ID"},
          {:path, :symbol, "self, tuple:N, map:key, or slash-separated nested fields"},
          {:kind, :symbol, "value, forward, test, or raise"}
        ],
        doc: """
        An exact call result or field is read by a non-copy, non-projection \
        instruction. value consumes a projected field; forward consumes the whole \
        result (including returning or wrapping it); test examines shape or value \
        without establishing a successful verdict by itself. raise passes a value \
        to a raising instruction or known error/throw/exit API. A tail call forwards \
        its result at its own site. Missing identity is unknown, not unused.
        """
      },
      %{
        name: :security_result_precondition,
        layer: 2,
        fields: [
          {:id, :symbol, "producing call instruction ID"},
          {:func, :symbol, "owning function ID"},
          {:use, :symbol, "consuming instruction ID"},
          {:path, :symbol, "checked field path in this same result"},
          {:value, :symbol, "exact required literal, spelled by Terms.spell/1"}
        ],
        doc: """
        Every path to this specific use crosses a branch edge establishing that \
        this exact result field equals the literal. Tuple shape alone, another \
        invocation, a later check or a check on only one incoming path does not \
        establish this fact. Supported checks are exact equality, tagged tuples \
        and literal select arms; this is a local proof, not a callee contract.
        """
      },
      %{
        name: :security_result_exclusion,
        layer: 2,
        fields: [
          {:id, :symbol, "producing call instruction ID"},
          {:func, :symbol, "owning function ID"},
          {:use, :symbol, "consuming instruction ID"},
          {:path, :symbol, "checked field path in this same result"},
          {:value, :symbol, "excluded literal, spelled by Terms.spell/1"}
        ],
        doc: """
        Every path to this use crosses an edge excluding this exact literal from \
        the same result field. Exact inequality and a select's default provide \
        exclusions. Excluding false proves true only with a separate guarantee \
        that the result is boolean; arbitrary truthy values are not true.
        """
      },
      %{
        name: :security_result_discarded,
        layer: 2,
        fields: [
          {:id, :symbol, "producing call instruction ID"},
          {:func, :symbol, "owning function ID"},
          {:at, :symbol, "instruction discarding its last copy or returning without it"}
        ],
        doc: """
        The result and its copies are discarded without being read on the linear \
        path following this call. A branch, unsupported instruction, projection, \
        test or forwarding operation ends this proof. Absence is not evidence \
        that the result was checked.
        """
      }
    ])
  end
end
