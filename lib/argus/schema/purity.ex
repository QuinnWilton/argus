defmodule Argus.Schema.Purity do
  @moduledoc """
  Purity contracts, and how each call a checked function makes is
  classified.

  Layer 2 of `Argus.Schema`, which reads the relations from here.
  """

  @doc "The relations, in the order `Argus.Schema.all/0` lists them."
  @spec relations() :: [Argus.Schema.declaration()]
  def relations do
    [
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
        A function its module declared free of observable effects with \
        `@pure true` (see `Argus.Purity`).

        Read out of the beam's persisted attribute chunk, so the contract comes \
        from the compiled artifact and cannot drift from the code it describes.
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
        A call with a known observable effect, classified by \
        `Argus.Purity.Effects`. The category says WHAT the effect is; the mode \
        says whether it changes anything.

        Both dimensions are needed because contracts differ in what they \
        forbid. Purity rejects reads and writes alike — `Application.get_env/2` \
        already breaks referential transparency. A transaction body only cares \
        about writes: a config read has nothing to roll back, while an HTTP \
        POST has already left the machine. One dimension would force every \
        config read to be reported as a transaction hazard.
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
        A call that dispatches through a protocol, so its target is whichever \
        implementation the argument's type provides.

        Distinct from `unknown_call`: that one means the effect model has no \
        entry, which somebody could add. This one means there is no single \
        answer to have — any module may define an implementation, and it is \
        ordinary code that can do anything.
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
        A call the effect model has no opinion about — neither known-impure nor \
        known-pure.

        Recorded rather than ignored because purity is a claim about every \
        execution. Assuming unknown calls are harmless would make a \
        verification report success far more often and mean nothing.
        """
      }
    ]
  end
end
