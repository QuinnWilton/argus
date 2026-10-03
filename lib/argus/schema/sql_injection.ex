defmodule Argus.Schema.SqlInjection do
  @moduledoc "SQL construction contexts and their narrowly scoped escaping proofs."

  @doc "The SQL relations, in schema order."
  @spec relations() :: [Argus.Schema.declaration()]
  def relations do
    Argus.Schema.Reads.record("relations #{__MODULE__}", [
      %{
        name: :sql_input,
        layer: 2,
        fields: fields(),
        doc: """
        A parameter contributes bytes to an SQL statement, quoted identifier, string, \
        comment, or dollar-quoted block. Query API bound parameters are excluded. \
        Query callback tuples require a recognized SQL prefix. A Postgrex.Stream's \
        persisted comment option is a deferred SQL comment boundary. State fields \
        count as input because previously supplied names can survive in state.
        """
      },
      %{
        name: :sql_input_safe,
        layer: 2,
        fields: fields(),
        doc: """
        Every alternative of this input at this construction protects this SQL \
        context. Double-quote doubling protects identifiers only in a known \
        PostgreSQL or SQLite dialect; it does not protect an enclosing dollar quote. \
        A fresh dollar delimiter must be selected by testing absence from this \
        same body; the body's own SQL construction remains checked. Unknown \
        reaching alternatives establish no safety. Comment validation must \
        reject both null bytes and */ for the same option before it is persisted, \
        on every returning path. Arbitrary replacement establishes no safety.
        """
      },
      %{
        name: :sql_call_input,
        layer: 2,
        fields: call_fields(),
        doc: """
        Parameter-derived bytes in the first argument of a query/query! call. \
        This is only a candidate: the callee must independently be proven to \
        implement a generated SQL adapter API before this becomes a sink. \
        The dialect is unknown; bound-value arguments are excluded.
        """
      },
      %{
        name: :sql_call_input_safe,
        layer: 2,
        fields: call_fields(),
        doc: """
        Every alternative of this candidate call argument protects the stated \
        SQL context under an unknown dialect, with the same proof requirements \
        as sql_input_safe. Callee identity is part of the proof.
        """
      }
    ])
  end

  defp fields do
    [
      {:id, :symbol, "SQL construction or query call instruction ID"},
      {:func, :symbol, "containing function ID"},
      {:context, :symbol, "statement, identifier, string, comment, or dollar_quote"},
      {:param, :number, "zero-based contributing parameter"}
    ]
  end

  defp call_fields do
    [id, func | rest] = fields()
    [id, func, {:callee, :symbol, "candidate query function ID"} | rest]
  end
end
