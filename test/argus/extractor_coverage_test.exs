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

  # Which relations each extractor can emit, read from its source rather
  # than by running it. Running under-approximates: `Argus.Extractors.Endpoint`
  # only emits for a module defining `__sockets__/0`, and no fixture has one,
  # so a discovery pass would call the relation unproduced and this test
  # would fail on correct code.
  defp extractor_outputs do
    for extractor <-
          Analysis.builtin_analysis_modules() |> Enum.flat_map(& &1.extractors()) |> Enum.uniq(),
        into: %{} do
      path =
        extractor
        |> Module.split()
        |> Enum.map_join("/", &Macro.underscore/1)
        |> then(&"lib/#{&1}.ex")

      relations =
        case File.read(path) do
          {:ok, src} ->
            # Both spellings: `add_fact(acc, :rel, ...)` and the pipe form
            # `|> add_fact(:rel, ...)`, where the accumulator is implicit.
            ~r/(?:add_fact|track_imprecision|track_dynamic)\(\s*(?:[^,:()]+,\s*)*:([a-z_0-9]+)/
            |> Regex.scan(src)
            |> MapSet.new(fn [_, name] -> String.to_atom(name) end)

          {:error, _} ->
            MapSet.new()
        end

      {extractor, relations}
    end
  end

  # Derived by stage 0 or by clientlib rules, not by any extractor.
  @derived MapSet.new([:call_edge, :call_site, :unconditional_call_edge, :call_reachable])

  # A defect the same run found, on the same shape as the CallArgs one that
  # is now fixed. `purity` reads `ets_new`, `ets_op` and `port_open` to
  # classify table and port operations as effects, and declares only
  # `Argus.Extractors.Purity` — so those facts are never emitted and the
  # purity contract has been blind to ETS writes and port opens. Same
  # one-line fix, same need to read the deltas, since it will make
  # previously-verified functions unprovable.
  @known_gaps MapSet.new([:ets_new, :ets_op, :port_open, :process_register])

  # `track_imprecision(facts, ctx, category, relation, reason)` names the
  # relation in its FOURTH argument, after a category atom — so a
  # first-atom scan reads the category. Rather than special-case the
  # helper's shape here, `imprecision` is exempt: it is coverage
  # instrumentation, not an analysis input anyone reasons from.
  @instrumentation MapSet.new([:imprecision])

  # A blind spot in the scan, not a defect in the code. A table-driven
  # extractor names its relation through a variable —
  # `Argus.Extractors.EctoSchema` does `@keys %{fields: :schema_field,
  # redact_fields: :redacted_field}` and then `add_fact(acc, relation, ...)`
  # — so no literal appears at the call site. Scanning source cannot see it,
  # and running the extractor would (it emits for any Ecto schema), which is
  # the trade the other direction: running under-approximates for extractors
  # no fixture exercises. Both approaches have holes; this one is named.
  @scan_blind MapSet.new([:schema_field, :redacted_field])

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
          not MapSet.member?(@known_gaps, atom),
          not MapSet.member?(@instrumentation, atom),
          not MapSet.member?(@scan_blind, atom),
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
