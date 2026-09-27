defmodule Argus.Schema.Coverage do
  @moduledoc """
  Coverage instrumentation: where an extractor fell back to "dynamic".
  Populated only when the active analysis run has imprecision tracking
  enabled (the `coverage` analysis).

  Layer 2 of `Argus.Schema`, which reads the relations from here.
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
        Tracks every fallback to a "dynamic" placeholder or an outright \
        skipped fact emission. Populated only when imprecision tracing is \
        enabled for the current pipeline run — the `coverage` analysis turns \
        it on, every other analysis runs with tracing off and produces no \
        rows in this relation.

        The `category` vocabulary is documented in `lib/argus/extractor/helpers.ex` \
        and is treated as a versioned API: changes are noted in CHANGELOG so \
        coverage diff tooling can keep stable keys.
        """
      }
    ])
  end
end
