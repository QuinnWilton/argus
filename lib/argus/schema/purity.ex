defmodule Argus.Schema.Purity do
  @moduledoc """
  Layer-2 purity contracts and call-effect classifications. Exposed through \
  `Argus.Schema`.
  """

  @doc "The relations, in the order `Argus.Schema.all/0` lists them."
  @spec relations() :: [Argus.Schema.declaration()]
  def relations do
    Argus.Schema.Reads.record("relations #{__MODULE__}", [
      %{
        name: :pure_contract,
        layer: 2,
        fields: [
          {:func, :func_id, "the function declared pure"},
          {:mod, :symbol, "declaring module"},
          {:name, :symbol, "function name"},
          {:arity, :number, "function arity"}
        ],
        doc: """
        A function declared `@pure true` (`Argus.Purity`), read from the compiled BEAM's \
        persisted attributes.
        """
      },
      %{
        name: :impure_call,
        layer: 2,
        fields: [
          {:id, :instr_id, "instruction ID of the call"},
          {:caller, :func_id, "containing function ID"},
          {:api, :symbol, "the API called, as Mod.fun/arity"},
          {:category, :symbol,
           "io | logging | process | process_dict | ets | port | node | time | random | network | code_loading"},
          {:mode, :symbol, "read (observes state) or write (changes it)"}
        ],
        doc: """
        A known observable call effect (`Argus.Purity.Effects`). Category identifies the \
        effect; mode distinguishes reads from writes. Purity rejects both, while \
        transaction checks report only writes that cannot be rolled back.
        """
      },
      %{
        name: :protocol_dispatch,
        layer: 2,
        fields: [
          {:id, :instr_id, "instruction ID of the call"},
          {:caller, :func_id, "containing function ID"},
          {:api, :symbol, "the protocol function called"}
        ],
        doc: """
        A protocol-dispatched call whose target depends on the argument type. Unlike a \
        missing effect-model entry, this has no single target: implementations may \
        contain arbitrary effects.
        """
      },
      %{
        name: :unknown_call,
        layer: 2,
        fields: [
          {:id, :instr_id, "instruction ID of the call"},
          {:caller, :func_id, "containing function ID"},
          {:api, :symbol, "the API called, as Mod.fun/arity"},
          {:callee, :func_id, "the callee as a function ID, for contract lookup"}
        ],
        doc: """
        A call classified as neither pure nor impure by the effect model. Unknown \
        effects prevent proving purity.
        """
      }
    ])
  end
end
