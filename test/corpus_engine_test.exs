defmodule Argus.CorpusEngineTest do
  @moduledoc """
  What the corpus facts cache is keyed on: the code extraction reaches,
  and nothing that only reports on the facts — a digest over all of
  argus would re-extract every checkout on a prose edit.
  """

  use ExUnit.Case, async: true

  alias Argus.Corpus

  test "the engine is what extraction reaches, in this project and its dependencies" do
    modules = Corpus.engine_modules()

    for reached <- [
          Argus.Analysis,
          Argus.Pipeline.Emit,
          Argus.Pipeline.Writer,
          Argus.Schema,
          Argus.Cfg,
          Argus.Souffle,
          BeamSpy.BeamFile,
          CTF
        ] do
      assert reached in modules, "#{inspect(reached)} shapes the facts and is not digested"
    end

    for mod <- Argus.Analysis.builtin_analysis_modules(), extractor <- mod.extractors() do
      assert extractor in modules, "#{inspect(extractor)} is declared and is not digested"
    end
  end

  test "what only reports on the facts is not in the engine" do
    modules = Corpus.engine_modules()

    for analysis <- Argus.Analysis.builtin_analysis_modules() do
      refute analysis in modules, "#{inspect(analysis)} is prose and rules, not extraction"
    end

    for reporting <- [Argus.Findings, Argus.Corpus, Argus.Migrate, Mix.Tasks.Argus.Corpus] do
      refute reporting in modules
    end

    # Consolidated protocols are the build's dispatch tables.
    refute Collectable in modules
    refute String.Chars in modules
  end

  test "the digest is stable within a VM" do
    digest = Corpus.engine_digest()
    assert digest =~ ~r/^[0-9a-f]{64}$/
    assert Corpus.engine_digest() == digest
  end
end
