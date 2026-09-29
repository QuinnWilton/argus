defmodule Argus.Schema.Coverage do
  @moduledoc """
  Layer-2 extraction-coverage facts, exposed through `Argus.Schema`. Populated only when \
  imprecision tracing is enabled by the `coverage` analysis.
  """

  @doc "The relations, in the order `Argus.Schema.all/0` lists them."
  @spec relations() :: [Argus.Schema.declaration()]
  def relations do
    Argus.Schema.Reads.record("relations #{__MODULE__}", [
      %{
        name: :imprecision,
        layer: 2,
        fields: [
          {:category, :symbol,
           "what we were trying to resolve (e.g. genserver_callee, ets_table_name)"},
          {:func, :symbol, "function ID where the fallback occurred"},
          {:relation, :symbol, "the fact relation that received the dynamic placeholder"},
          {:reason, :symbol, "why imprecision: dynamic | unresolvable | skipped | missing"}
        ],
        doc: """
        An extractor fallback to `dynamic` or a skipped fact. Emitted only with \
        imprecision tracing, enabled by the `coverage` analysis. The versioned \
        `category` vocabulary is documented in `lib/argus/extractor/helpers.ex`; changes \
        are recorded in CHANGELOG for coverage-diff consumers.
        """
      }
    ])
  end
end
