defmodule Argus.Analyses.UnsafeInput.SqlInjection do
  @moduledoc "SQL injection findings with construction-specific escaping evidence."

  alias Argus.Findings

  @spec output_relations() :: [Argus.Analysis.output_relation()]
  def output_relations do
    [
      %{
        name: :sql_injection,
        fields: [
          {:id, :symbol, "SQL construction instruction"},
          {:func, :symbol, "function constructing SQL"},
          {:context, :symbol, "SQL lexical context"}
        ],
        key: [:id, :context],
        doc: "Caller-derived bytes enter SQL syntax without escaping for that context."
      }
    ]
  end

  @spec finding(atom(), [String.t()]) :: Findings.attrs()
  def finding(:sql_injection, [id, func, context]) do
    {title, explanation, help} = context(context)

    Findings.new(
      :error,
      title,
      "#{func} puts bytes derived from its input into #{explanation}. " <>
        "The value may include control bytes that change the query. Stored callback " <>
        "state can contain names supplied by earlier callers. Bound query parameters " <>
        "are separate from statement construction and do not trigger this finding.",
      at: Findings.at_instr(id),
      at_label: "input enters SQL #{context} here",
      help: [help]
    )
  end

  defp context("identifier") do
    {"SQL injection through a quoted identifier", "a double-quoted SQL identifier",
     "double every embedded double quote and keep the surrounding identifier quotes"}
  end

  defp context("dollar_quote") do
    {"SQL injection through a dollar-quoted block", "a dollar-quoted SQL block",
     "avoid embedding caller-controlled bytes in a dollar-quoted block; identifier quoting " <>
       "does not stop a matching dollar delimiter from ending the block. If a block is " <>
       "required, select a valid delimiter absent from the entire body before wrapping it"}
  end

  defp context("comment") do
    {"SQL injection through a query comment", "an SQL comment",
     "reject null bytes and comment terminators on the same comment before executing " <>
       "or persisting the query options"}
  end

  defp context("string") do
    {"SQL injection through an interpolated value", "an SQL string literal",
     "pass values through the database driver's bound parameter argument"}
  end

  defp context(_) do
    {"SQL injection through a dynamic statement", "SQL statement text",
     "keep statement syntax literal and pass values through the driver's bound parameters"}
  end
end
