defmodule Argus.CorpusEngineTest do
  @moduledoc """
  A checkout's store and how it is pruned. What the facts are keyed on
  is `Argus.Cache.CodeTest`'s.
  """

  use ExUnit.Case, async: true

  alias Argus.Corpus

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

  @tag :tmp_dir
  test "kept solves are pruned by the same policy, each program on its own",
       %{tmp_dir: solves} do
    entries(solves, [
      {"races-#{digest("a")}", 5 * @hour},
      {"races-#{digest("b")}", 4 * @hour},
      {"races-#{digest("c")}", 3 * @hour},
      {"races-#{digest("d")}", 60},
      {"points_to-#{digest("a")}", 9 * @hour},
      {"points_to-#{digest("b")}.123.4", 25 * @hour},
      {"notes", 48 * @hour}
    ])

    # races keeps its live solve and its most recent other; points_to's
    # one solve is its most recent; the day-old staging directory goes.
    assert Corpus.prune_solves(solves, recent: 1) ==
             Enum.map(
               ["points_to-#{digest("b")}.123.4", "races-#{digest("a")}", "races-#{digest("b")}"],
               &Path.join(solves, &1)
             )

    assert Enum.sort(File.ls!(solves)) ==
             ["notes", "points_to-#{digest("a")}", "races-#{digest("c")}", "races-#{digest("d")}"]
  end

  @tag :tmp_dir
  test "the solves of every installed entry are found, and no other", %{tmp_dir: cache} do
    entries(cache, [{digest("a"), 0}, {digest("b"), 0}, {"#{digest("c")}.1.2", 0}])
    File.mkdir_p!(Path.join([cache, digest("a"), "solves"]))
    File.mkdir_p!(Path.join([cache, "#{digest("c")}.1.2", "solves"]))

    assert Corpus.solve_caches(cache) == [Path.join([cache, digest("a"), "solves"])]
  end

  test "a missing cache has nothing to prune" do
    assert Corpus.stale_facts("/nonexistent/argus-facts") == []
  end

  @tag :tmp_dir
  test "a checkout's store is pruned with the entries an older argus kept whole",
       %{tmp_dir: cache} do
    shard = "shards/base-0123456789abcdef-"

    entries(cache, [
      {digest("a"), 5 * @hour},
      {digest("b"), 4 * @hour},
      {shard <> digest("a"), 5 * @hour},
      {shard <> digest("b"), 60},
      {shard <> digest("c"), 3 * @hour}
    ])

    # Legacy entries and each producer's shards keep their one most
    # recent; the live shard stays too.
    assert Corpus.stale_facts(cache, recent: 1) ==
             Enum.map([digest("a"), shard <> digest("a")], &Path.join(cache, &1))
  end

  test "a checkout's store is beside it" do
    assert Corpus.store(%{dir: "/corpus/oban-1234567"}) == "/corpus/oban-1234567/.argus-facts"
  end
end
