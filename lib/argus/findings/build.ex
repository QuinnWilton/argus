defmodule Argus.Findings.Build do
  @moduledoc """
  An analysis's solved rows, made findings.

  For each output relation the analysis declares, in name order: rows
  are deduplicated by the relation's key (`Argus.Findings.Rows`), each
  row goes through the analysis's `finding/2` callback (or, without one,
  a generic `:info` rendering of the relation's doc and the row's
  columns), the frames of its evidence rows are appended to its
  `related` (`Argus.Findings.Evidence`), it steps down a level when its
  module is one the analysis's `tooling` rows name (`retier: :tooling`,
  `Argus.Findings.Tooling`), it is stamped with the analysis's name, and
  its prose is put in plain names (`Argus.Findings.Names`).

  A builder that raises on a row costs that row only: the row is
  reported with its raw columns (a generic finding, or a generic frame
  for an evidence row) under a help line that says so, and the failure
  is returned beside the findings for `Argus.Findings.run/2` to report as
  a degradation.

  `Argus.Findings.build/2` is the public entry; it drops the failures.
  """

  alias Argus.Analysis
  alias Argus.Findings
  alias Argus.Findings.Anchor
  alias Argus.Findings.Evidence
  alias Argus.Findings.Names
  alias Argus.Findings.Rows
  alias Argus.Findings.Tooling

  @typedoc "A row whose builder raised: its relation, the row, and the exception."
  @type failure :: %{relation: atom(), row: [String.t()], exception: Exception.t()}

  @doc """
  The findings of `mod` from `results` (relation name strings to rows),
  and the rows whose builder raised. Relations the analysis does not
  declare as outputs are ignored.
  """
  @spec build(module(), %{String.t() => [[String.t()]]}) :: {[Findings.finding()], [failure()]}
  def build(mod, results) do
    relations = Map.new(mod.output_relations(), &{Atom.to_string(&1.name), &1})
    results = Map.take(results, Map.keys(relations))
    has_builder? = function_exported?(mod, :finding, 2)
    joins = Evidence.joins(mod, relations)
    {evidence, evidence_failures} = Evidence.frames(mod, relations, results, joins, &guarded/4)
    tooling = tooling(relations, results)

    {findings, failures} =
      for {relation_string, rows} <- Enum.sort(results),
          relation = Map.fetch!(relations, relation_string),
          not Map.has_key?(relation, :evidence),
          not Map.has_key?(relation, :retier),
          row <- Rows.dedupe(relation, rows),
          reduce: {[], []} do
        {findings, failures} ->
          {attrs, failures} =
            if has_builder? do
              guarded(relation, row, failures, fn -> mod.finding(relation.name, row) end)
            else
              {generic_finding(relation, row), failures}
            end

          finding =
            attrs
            |> Map.update(:related, [], &(&1 ++ Evidence.for_row(evidence, joins, relation, row)))
            |> Tooling.retier(tooling)
            |> Map.delete(:floor)
            |> Map.put(:analysis, mod.name())
            |> Map.put(:concern, mod.name())
            |> Names.render()

          {[finding | findings], failures}
      end

    {Enum.reverse(findings), Enum.reverse(failures) ++ evidence_failures}
  end

  # The modules the analysis's `retier: :tooling` relation names, if it
  # declares one.
  defp tooling(relations, results) do
    rows =
      for {name, %{retier: :tooling}} <- relations,
          row <- Map.get(results, name, []),
          do: row

    Tooling.index(rows)
  end

  # One row's builder, run so that its crash costs that row only: the
  # row falls back to the generic rendering (a finding, or for an
  # evidence row a frame), which names the crash.
  @spec guarded(Analysis.output_relation(), [String.t()], [failure()], (-> term())) ::
          {term(), [failure()]}
  defp guarded(relation, row, failures, build) do
    {build.(), failures}
  rescue
    exception ->
      note =
        "Argus could not render this #{relation.name} row " <>
          "(#{Exception.message(exception)}) and shows its raw columns; this is a bug in Argus"

      fallback =
        if Map.has_key?(relation, :evidence) do
          Findings.related(note <> ": " <> Rows.raw_columns(relation, row), Anchor.from_row(row))
        else
          Map.update!(generic_finding(relation, row), :help, &(&1 ++ [note]))
        end

      {fallback, [%{relation: relation.name, row: row, exception: exception} | failures]}
  end

  # Fallback for behaviour implementors that don't define finding/2:
  # severity :info, prose from the relation's declared doc, anchor from
  # the first row value that parses as an instruction or function ID.
  defp generic_finding(relation, row) do
    Findings.new(
      :info,
      humanize(relation.name),
      "#{relation.doc} (#{Rows.raw_columns(relation, row)})",
      at: Anchor.from_row(row)
    )
  end

  defp humanize(relation_name) do
    relation_name
    |> Atom.to_string()
    |> String.replace("_", " ")
    |> String.capitalize()
  end
end
