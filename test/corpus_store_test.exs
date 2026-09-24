defmodule Argus.CorpusStoreTest do
  # Sync on purpose: the corpus's root is ARGUS_CORPUS_DIR, read from the
  # VM-wide environment.
  use ExUnit.Case, async: false

  alias Argus.Corpus

  # They test the store, which ARGUS_NO_CACHE turns off.
  @moduletag :cache

  # Kept between runs, as a real checkout is, so a warm run of this test
  # solves nothing either.
  defp root, do: Path.join(Mix.Project.build_path(), "argus-corpus-test")

  @modules [Argus.Test.Fixtures.EtsBounded, Argus.Test.Fixtures.MissingRow]

  # A checkout as `Corpus.ensure/2` leaves one: a clone with a mix.exs
  # naming its app, marked compiled, its beams in `_build/dev`.
  defp fake_checkout!(root, pair) do
    %{dir: dir} = Corpus.checkout(pair, :pre)
    ebin = Path.join([dir, "_build", "dev", "lib", "fake", "ebin"])
    File.mkdir_p!(ebin)
    File.write!(Path.join(dir, "mix.exs"), "def project, do: [app: :fake]\n")
    File.write!(Path.join(dir, ".argus-compiled-#{String.slice(pair.pre, 0, 7)}"), "")

    for mod <- @modules do
      target = Path.join(ebin, "#{mod}.beam")
      beam = File.read!(to_string(:code.which(mod)))
      if File.read(target) != {:ok, beam}, do: File.write!(target, beam)
    end

    Path.join(root, Path.basename(dir))
  end

  defp entries(store) do
    for kind <- ~w(shards solves), name <- File.ls!(Path.join(store, kind)), do: {kind, name}
  end

  setup do
    before = System.get_env("ARGUS_CORPUS_DIR")
    System.put_env("ARGUS_CORPUS_DIR", root())

    on_exit(fn ->
      if before,
        do: System.put_env("ARGUS_CORPUS_DIR", before),
        else: System.delete_env("ARGUS_CORPUS_DIR")
    end)
  end

  test "a checkout is analyzed through its store, and a second analysis runs nothing again" do
    unless Argus.Souffle.available?(), do: flunk("souffle not installed")

    pair = %{repo: "nobody/fake", issue: "fake#1", pre: "abcdef1234", finding: {:ets, "-"}}
    dir = fake_checkout!(root(), pair)
    store = Corpus.store(Corpus.checkout(pair, :pre))
    assert store == Path.join(dir, ".argus-facts")

    assert {:ok, first} = Corpus.analyze(pair, :pre)
    kept = entries(store)
    assert Enum.count(kept, &(elem(&1, 0) == "solves")) > 1

    assert {:ok, again} = Corpus.analyze(pair, :pre)
    assert again.findings == first.findings
    assert entries(store) == kept

    # Pruning leaves what a run touched within the hour.
    assert Corpus.prune_facts(store) == []
  end
end
