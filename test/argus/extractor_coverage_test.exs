defmodule Argus.ExtractorCoverageTest do
  @moduledoc """
  Guards the link between what an analysis reads and what its extractors
  produce.

  An analysis lists its inputs implicitly — Souffle reports which relations
  its rules actually join — and its extractors explicitly, in
  `extractors/0`. Nothing checked that the second covers the first, and the
  gap is silent in the worst way: Souffle happily reads an empty `.facts`
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
  those, so no extractor need claim them.
  """

  use ExUnit.Case, async: true

  alias Argus.{Analysis, Schema, Souffle}

  # Which relations each extractor can emit, as it declares them; the
  # declaration is held to the source by Argus.ExtractorRelationsTest.
  defp extractor_outputs do
    for extractor <-
          Analysis.builtin_analysis_modules() |> Enum.flat_map(& &1.extractors()) |> Enum.uniq(),
        into: %{},
        do: {extractor, MapSet.new(extractor.relations())}
  end

  # Derived by stage 0 or by clientlib rules, not by any extractor.
  @derived MapSet.new([:call_edge, :call_site, :unconditional_call_edge, :call_reachable])

  # `track_imprecision(facts, ctx, category, relation, reason)` names the
  # relation in its FOURTH argument, after a category atom — so a
  # first-atom scan reads the category. Rather than special-case the
  # helper's shape here, `imprecision` is exempt: it is coverage
  # instrumentation, not an analysis input anyone reasons from.
  @instrumentation MapSet.new([:imprecision])

  setup do
    unless Souffle.available?(), do: ExUnit.configure(exclude: [souffle: true])
    :ok
  end

  @tag :souffle
  test "every Layer-2 relation an analysis reads is produced by one of its extractors" do
    layer_1 = Schema.layer_1() |> Enum.map(& &1.name) |> MapSet.new()
    outputs = extractor_outputs()

    gaps =
      for mod <- Analysis.builtin_analysis_modules(),
          {:ok, reads} = Analysis.input_relations(mod.name()),
          produced =
            mod.extractors()
            |> Enum.map(&Map.get(outputs, &1, MapSet.new()))
            |> Enum.reduce(MapSet.new(), &MapSet.union/2),
          relation <- reads,
          atom = String.to_atom(relation),
          not MapSet.member?(layer_1, atom),
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
end
