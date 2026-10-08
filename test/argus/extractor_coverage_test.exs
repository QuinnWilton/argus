defmodule Argus.ExtractorCoverageTest do
  @moduledoc """
  Guards the link between what an analysis reads and what its extractors
  produce.

  An analysis lists its inputs implicitly — FlowLog reports which relations
  its rules actually join — and its extractors explicitly, in
  `extractors/0`. Nothing checked that the second covers the first, and the
  gap is silent in the worst way: an engine happily reads an empty `.facts`
  file, every rule touching that relation derives nothing, and the analysis
  reports a clean zero indistinguishable from a codebase with no such bug.

  This happened four times in one sweep, and the fourth is the reason the
  guard exists rather than a fix in each analysis: `call_arg` and
  `call_arg_forward` were emitted only by `Argus.Extractors.CallArgs`,
  which NO analysis declared, so `clientlib/interprocedural.dl` — the whole
  argument-forwarding layer — derived nothing across the seven analyses
  that include it.

    * `network_in_init` read `impure_call` while `sync_call_in_init` did not
      declare the Purity extractor. Zero findings on every project.
    * `unmatched_message` read `callback_partial` the same way.
    * The self-directed `sync_call` resolution read `callback_tag` and
      `tuple_literal` while all four consuming analyses declared neither.
      Findings were byte-identical before and after a change measured at
      90-96% coverage, and the only reason it was caught is that a delta of
      exactly zero was not believable.

  Layer-1 relations are excluded: `Argus.Pipeline.Emit` always produces
  those, so no extractor need claim them. An analysis that reads the
  points-to stage's outputs reads what that stage reads, from the same
  extraction: its extractors must fill those too.
  """

  use ExUnit.Case, async: true

  alias Argus.{Analysis, Schema}

  # Which relations each extractor can emit, as it declares them; the
  # declaration is held to the source by Argus.ExtractorRelationsTest.
  defp extractor_outputs do
    for extractor <-
          Analysis.builtin_analysis_modules() |> Enum.flat_map(& &1.extractors()) |> Enum.uniq(),
        into: %{},
        do: {extractor, MapSet.new(extractor.relations())}
  end

  # Derived by stage 0 or by clientlib rules, not by any extractor.
  @derived MapSet.new([
             :call_edge,
             :call_site,
             :unconditional_call_edge,
             :call_tag,
             :fun_handed_to,
             :fun_built,
             :call_reachable
           ])

  # `track_imprecision(facts, ctx, category, relation, reason)` names the
  # relation in its FOURTH argument, after a category atom — so a
  # first-atom scan reads the category. Rather than special-case the
  # helper's shape here, `imprecision` is exempt: it is coverage
  # instrumentation, not an analysis input anyone reasons from.
  @instrumentation MapSet.new([:imprecision])

  @tag :flowlog
  test "every Layer-2 relation an analysis reads is produced by one of its extractors" do
    layer_1 = Schema.layer_1() |> Enum.map(& &1.name) |> MapSet.new()
    # A prior is filled by a question, not an extractor; that pairing is
    # Argus.ExtractorRelationsTest's to check, and an empty prior is the
    # documented meaning of "priors off", not a clean zero in disguise.
    priors = Schema.layer_3() |> Enum.map(& &1.name) |> MapSet.new()
    outputs = extractor_outputs()
    staged = Analysis.points_to_relations()
    {:ok, stage_reads} = Argus.FlowLog.input_relations(Analysis.points_to_rules_path())

    gaps =
      for mod <- Analysis.builtin_analysis_modules(),
          {:ok, reads} = Analysis.input_relations(mod.name()),
          reads = through_points_to(reads, staged, stage_reads),
          produced =
            mod.extractors()
            |> Enum.map(&Map.get(outputs, &1, MapSet.new()))
            |> Enum.reduce(MapSet.new(), &MapSet.union/2),
          relation <- reads,
          atom = String.to_atom(relation),
          not MapSet.member?(layer_1, atom),
          not MapSet.member?(priors, atom),
          not MapSet.member?(@derived, atom),
          not MapSet.member?(@instrumentation, atom),
          not MapSet.member?(produced, atom) do
        "#{mod.name()} reads #{relation}, but none of its extractors " <>
          "(#{Enum.map_join(mod.extractors(), ", ", &inspect/1)}) emits it"
      end

    assert gaps == [],
           "an analysis reading a relation nothing fills reports a clean zero, " <>
             "which is indistinguishable from a codebase with no such bug:\n" <>
             Enum.join(gaps, "\n")
  end

  # An analysis's reads, with the staged points-to relations it reads
  # replaced by what the stage reads to derive them.
  defp through_points_to(reads, staged, stage_reads) do
    if Enum.any?(reads, &(&1 in staged)),
      do: Enum.uniq((reads -- staged) ++ stage_reads),
      else: reads
  end
end
