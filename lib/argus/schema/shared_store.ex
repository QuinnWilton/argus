defmodule Argus.Schema.SharedStore do
  @moduledoc "Shared-cache row identities and isolation facts for replay claims."

  @doc "The shared-store extractor's relations."
  @spec relations() :: [Argus.Schema.declaration()]
  def relations do
    Argus.Schema.Reads.record("relations #{__MODULE__}", [
      %{
        name: :shared_store_op,
        layer: 2,
        fields: [
          {:site, :instr_id, "the ConCache call"},
          {:func, :func_id, "the containing function"},
          {:operation, :symbol, "get | put"},
          {:store_source, :symbol,
           "identity source, optionally prefixed by a pure unary transform"},
          {:store, :symbol, "the store identity"},
          {:key_source, :symbol,
           "identity source, optionally prefixed by a pure unary transform"},
          {:key, :symbol, "the key identity"}
        ],
        doc: "An individual shared-cache read or non-atomic write, identified by store and key."
      },
      %{
        name: :shared_store_argument,
        layer: 2,
        fields: [
          {:site, :instr_id, "the exact call site"},
          {:caller, :func_id, "the caller"},
          {:callee, :func_id, "the callee"},
          {:position, :number, "0-based argument position"},
          {:transform, :symbol, "pure unary leaf helper applied to the argument, or empty"},
          {:source, :symbol, "Identity.key_identity source of the argument or transform input"},
          {:value, :symbol, "the argument or transform input identity"}
        ],
        doc:
          "Call arguments retain local origins and stable unary normalization for shared row identity."
      },
      %{
        name: :shared_store_transform,
        layer: 2,
        fields: [{:func, :func_id, "a pure unary leaf helper used to normalize a store or key"}],
        doc: "A deterministic key expression whose equal input identities produce the same key."
      },
      %{
        name: :shared_store_callback,
        layer: 2,
        fields: [
          {:caller, :func_id, "the caller of ConCache.isolated/3"},
          {:callback, :func_id, "the actual callback whose verdict isolated/3 returns"}
        ],
        doc: "A synchronous isolation callback returns its verdict to this caller."
      },
      %{
        name: :shared_store_gate,
        layer: 2,
        fields: [
          {:site, :instr_id, "a call protected by the equality branch"},
          {:func, :func_id, "the containing function"},
          {:kind, :symbol, "site | call"},
          {:source, :symbol, "the exact tested call site's ID"},
          {:value, :symbol, "the literal result required on every path to this call"}
        ],
        doc: "This call is reached only through an equality branch of this exact call result."
      },
      %{
        name: :shared_store_returned_call,
        layer: 2,
        fields: [
          {:func, :func_id, "the returning function"},
          {:kind, :symbol, "site | call"},
          {:source, :symbol, "the exact call site whose unchanged result is returned"}
        ],
        doc:
          "Transparent call-result returns; copied fields or control-selected data do not qualify."
      },
      %{
        name: :shared_store_return_choice,
        layer: 2,
        fields: [
          {:func, :func_id, "the containing function"},
          {:kind, :symbol, "site | call"},
          {:source, :symbol, "the exact tested call site's ID"},
          {:tested, :symbol, "the required literal call result"},
          {:returned, :symbol, "the literal atom returned on this branch"}
        ],
        doc:
          "A wrapper maps a required result to a literal return; used to retain absence polarity."
      },
      %{
        name: :shared_store_lock,
        layer: 2,
        fields: [
          {:func, :func_id, "the actual ConCache.isolated/3 closure"},
          {:store_source, :symbol, "the protected cache identity in the closure"},
          {:store, :symbol, "protected cache"},
          {:key_source, :symbol, "the protected key identity in the closure"},
          {:key, :symbol, "protected key"}
        ],
        doc:
          "The cache/key pair ConCache.isolated serializes, translated to the closure's parameters."
      }
    ])
  end
end
