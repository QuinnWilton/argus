defmodule Argus.Findings.Evidence do
  @moduledoc """
  Evidence relations: rows that are related frames of another
  relation's findings rather than findings of their own.

  An output relation that declares `evidence: %{of: finding_relation,
  on: columns}` (`t:Argus.Analysis.evidence/0`) joins the finding
  relation on those columns. `Argus.Findings.build/2` reads the joins
  once per build (`joins/2`), renders each deduplicated evidence row
  through the analysis's `evidence/2` callback (`frames/5`), and appends
  a finding's frames to its `related` (`for_row/4`) — the cycle edges of
  a call cycle, the callers queued on a bottleneck, the routes a sink
  sits behind.
  """

  alias Argus.Analysis
  alias Argus.Findings
  alias Argus.Findings.Rows

  @typedoc """
  How each finding relation joins its evidence: finding relation name =>
  `{evidence relation name, [{evidence position, finding position}]}`.
  """
  @type joins :: %{atom() => {atom(), [{non_neg_integer(), non_neg_integer()}]}}

  @typedoc """
  The rendered frames, keyed by the finding relation they join and the
  values of the join columns.
  """
  @type frames :: %{{atom(), [String.t()]} => [Findings.related()]}

  @typedoc """
  How a row is rendered so that its crash costs that row only: given the
  relation, the row, the failures so far and the builder, the rendered
  value and the failures after it (`Argus.Findings.Build`'s guard).
  """
  @type guard :: (Analysis.output_relation(), [String.t()], [map()], (-> term()) ->
                    {term(), [map()]})

  @doc """
  The joins an analysis's relations declare (`relations` maps relation
  name strings to the relations). A finding relation has at most one
  evidence relation, and it must be one the analysis declares; either
  mistake is a bug in the analysis module, not in the rows, and raises.
  """
  @spec joins(module(), %{String.t() => Analysis.output_relation()}) :: joins()
  def joins(mod, relations) do
    by_name = Map.new(relations, fn {_string, relation} -> {relation.name, relation} end)

    for {_string, %{evidence: %{of: of, on: on}} = evidence} <- relations, reduce: %{} do
      acc ->
        finding =
          Map.get(by_name, of) ||
            raise ArgumentError,
                  "#{inspect(mod)}: evidence relation #{inspect(evidence.name)} joins " <>
                    "#{inspect(of)}, which is not one of its output relations"

        if Map.has_key?(acc, of) do
          raise ArgumentError,
                "#{inspect(mod)}: #{inspect(of)} has two evidence relations, " <>
                  "#{inspect(elem(acc[of], 0))} and #{inspect(evidence.name)}"
        end

        positions =
          for pair <- on do
            {Rows.position(evidence, evidence_column(pair)),
             Rows.position(finding, finding_column(pair))}
          end

        Map.put(acc, of, {evidence.name, positions})
    end
  end

  @doc """
  Related frames from the evidence relations: one frame per deduplicated
  evidence row, in row order, at most `limit` of them per finding when
  the relation sets one (the first in row order — a sample, for "the
  other sites do this", not a census). Each row is rendered by
  `mod.evidence/2` under `guard`; the failures it records come back
  beside the frames.
  """
  @spec frames(
          module(),
          %{String.t() => Analysis.output_relation()},
          %{String.t() => [[String.t()]]},
          joins(),
          guard()
        ) :: {frames(), [map()]}
  def frames(mod, relations, results, joins, guard) do
    {frames, failures} =
      for {of, {evidence_name, positions}} <- joins,
          evidence = Map.fetch!(relations, Atom.to_string(evidence_name)),
          row <-
            Rows.dedupe(evidence, Enum.sort(Map.get(results, Atom.to_string(evidence_name), []))),
          reduce: {%{}, []} do
        {acc, failures} ->
          key = {of, Enum.map(positions, fn {at, _} -> Enum.at(row, at) end)}
          limit = Map.get(evidence.evidence, :limit)

          case Map.get(acc, key, {0, []}) do
            {count, _frames} when limit != nil and count >= limit ->
              {acc, failures}

            {count, frames} ->
              {frame, failures} =
                guard.(evidence, row, failures, fn -> mod.evidence(evidence_name, row) end)

              {Map.put(acc, key, {count + 1, [frame | frames]}), failures}
          end
      end

    {Map.new(frames, fn {key, {_count, frames}} -> {key, Enum.reverse(frames)} end),
     Enum.reverse(failures)}
  end

  @doc "The frames a finding row of `relation` joins, in row order."
  @spec for_row(frames(), joins(), Analysis.output_relation(), [String.t()]) ::
          [Findings.related()]
  def for_row(frames, joins, relation, row) do
    case Map.fetch(joins, relation.name) do
      {:ok, {_evidence_name, positions}} ->
        join = Enum.map(positions, fn {_, at} -> Enum.at(row, at) end)
        Map.get(frames, {relation.name, join}, [])

      :error ->
        []
    end
  end

  defp evidence_column({column, _finding_column}), do: column
  defp evidence_column(column) when is_atom(column), do: column
  defp finding_column({_evidence_column, column}), do: column
  defp finding_column(column) when is_atom(column), do: column
end
