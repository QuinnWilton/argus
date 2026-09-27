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

  @pair %{repo: "nobody/fake", issue: "fake#1", pre: "abcdef1234", finding: {:ets, "-"}}

  # On the backend `ARGUS_BACKEND` names, for the length of `fun`: the
  # variable is VM-wide, and this module is sync.
  defp on_backend(backend, fun) do
    before = System.get_env("ARGUS_BACKEND")
    System.put_env("ARGUS_BACKEND", Atom.to_string(backend))

    try do
      fun.()
    after
      if before,
        do: System.put_env("ARGUS_BACKEND", before),
        else: System.delete_env("ARGUS_BACKEND")
    end
  end

  # What every database of the node executed while `fun` ran.
  defp executed(fun) do
    log = Roux.QueryLog.start(:all)

    try do
      {fun.(), Roux.QueryLog.by_query(log, :execution)}
    after
      Roux.QueryLog.stop(log)
    end
  end

  test "on the graph, a checkout keeps its manifest, and a second analysis executes nothing" do
    unless Argus.Souffle.available?(), do: flunk("souffle not installed")

    _dir = fake_checkout!(root(), @pair)
    manifest = Corpus.manifest(Corpus.checkout(@pair, :pre))

    on_backend(:graph, fn ->
      assert {:ok, first} = Corpus.analyze(@pair, :pre)
      assert File.regular?(manifest)

      {{:ok, again}, executed} = executed(fn -> Corpus.analyze(@pair, :pre) end)
      assert executed == %{}
      assert again.findings == first.findings
    end)
  end

  test "a worktree without a manifest starts from the newest another kept" do
    unless Argus.Souffle.available?(), do: flunk("souffle not installed")

    _dir = fake_checkout!(root(), @pair)
    manifest = Corpus.manifest(Corpus.checkout(@pair, :pre))

    on_backend(:graph, fn ->
      assert {:ok, first} = Corpus.analyze(@pair, :pre)

      # As another worktree left it: the older of two, then the newer.
      older = Path.join(Path.dirname(manifest), "manifest-older")
      newer = Path.join(Path.dirname(manifest), "manifest-newer")
      File.write!(older, "not a manifest")
      File.touch!(older, System.os_time(:second) - 60)
      File.rename!(manifest, newer)

      {{:ok, again}, executed} = executed(fn -> Corpus.analyze(@pair, :pre) end)
      assert File.regular?(manifest)
      # The same code computed the newer one's entries: they all hold.
      assert executed == %{}
      assert again.findings == first.findings
      File.rm!(older)
      File.rm!(newer)
    end)
  end

  test "on the batch backend, a checkout is analyzed through its store, and a second analysis runs nothing again" do
    unless Argus.Souffle.available?(), do: flunk("souffle not installed")

    pair = @pair
    dir = fake_checkout!(root(), pair)
    store = Corpus.store(Corpus.checkout(pair, :pre))
    assert store == Path.join(dir, ".argus-facts")

    on_backend(:batch, fn -> batch_twice(pair, store) end)
  end

  defp batch_twice(pair, store) do
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
