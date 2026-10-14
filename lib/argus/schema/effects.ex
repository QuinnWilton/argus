defmodule Argus.Schema.Effects do
  @moduledoc """
  Layer-2 call-effect classifications (`Argus.EffectModel`). Exposed through \
  `Argus.Schema`.
  """

  @doc "The relations, in the order `Argus.Schema.all/0` lists them."
  @spec relations() :: [Argus.Schema.declaration()]
  def relations do
    Argus.Schema.Reads.record("relations #{__MODULE__}", [
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
        A known observable call effect (`Argus.EffectModel`). Category identifies the \
        effect; mode distinguishes reads from writes. Transaction checks report only \
        writes, since a read leaves a rollback nothing to undo.
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
          {:callee, :func_id, "the callee as a function ID, to join function_def"}
        ],
        doc: """
        A call classified as neither pure nor impure by the effect model. Each rule \
        decides what an unknown effect means for it.
        """
      }
    ])
  end
end
