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

  defp entries(cache, names_and_ages) do
    now = System.os_time(:second)

    for {name, age} <- names_and_ages do
      path = Path.join(cache, name)
      File.mkdir_p!(Path.join(path, "facts"))
      File.touch!(path, now - age)
    end
  end

  defp digest(char), do: String.duplicate(char, 64)

  @hour 60 * 60

  @tag :tmp_dir
  test "pruning spares the kept entry, anything touched within the hour, and the most recent",
       %{tmp_dir: cache} do
    entries(cache, [
      {digest("a"), 30 * @hour},
      {digest("b"), 60},
      {digest("c"), 2 * @hour},
      {digest("d"), 3 * @hour},
      {digest("e"), 4 * @hour},
      {digest("f"), 5 * @hour}
    ])

    # Beside the kept a and the live b, the two most recent of the rest.
    assert Corpus.stale_facts(cache, keep: digest("a"), recent: 2) ==
             Enum.map([digest("e"), digest("f")], &Path.join(cache, &1))

    assert Corpus.prune_facts(cache, keep: digest("a"), recent: 2) ==
             Enum.map([digest("e"), digest("f")], &Path.join(cache, &1))

    assert Enum.sort(File.ls!(cache)) == Enum.map(~w(a b c d), &digest/1)
  end

  @tag :tmp_dir
  test "a baseline outlives an hour of work under the default retention",
       %{tmp_dir: cache} do
    # A before-tally's entry, then three extraction changes, each tallied.
    entries(cache, [
      {digest("a"), 6 * @hour},
      {digest("b"), 4 * @hour},
      {digest("c"), 2 * @hour}
    ])

    entries(cache, [{digest("d"), 0}])
    assert Corpus.prune_facts(cache, keep: digest("d")) == []
  end

  @tag :tmp_dir
  test "nothing touched within the hour is pruned, however many there are",
       %{tmp_dir: cache} do
    entries(cache, for(c <- ~w(a b c d e f), do: {digest(c), 60}))
    assert Corpus.prune_facts(cache, recent: 0) == []
  end

  @tag :tmp_dir
  test "a staging directory is pruned only once a day has passed; other names never",
       %{tmp_dir: cache} do
    entries(cache, [
      {"#{digest("a")}.123.4", 2 * @hour},
      {"#{digest("b")}.123.5", 25 * @hour},
      {"notes", 48 * @hour}
    ])

    File.write!(Path.join(cache, digest("c")), "a file, not an entry")

    assert Corpus.stale_facts(cache, recent: 0) == [Path.join(cache, "#{digest("b")}.123.5")]
  end

  test "a missing cache has nothing to prune" do
    assert Corpus.stale_facts("/nonexistent/argus-facts") == []
  end

  test "the digest is stable within a VM" do
    digest = Corpus.engine_digest()
    assert digest =~ ~r/^[0-9a-f]{64}$/
    assert Corpus.engine_digest() == digest
  end
end
