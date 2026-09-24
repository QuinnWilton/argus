defmodule Argus.CacheEnvTest do
  # Sync on purpose: ARGUS_NO_CACHE is read from the VM-wide environment,
  # and a concurrent test would find its store turned off under it.
  use ExUnit.Case, async: false

  alias Argus.Souffle

  @moduletag :tmp_dir

  # The run's own value is put back, whatever the test set.
  setup do
    before = System.get_env("ARGUS_NO_CACHE")

    on_exit(fn ->
      if before,
        do: System.put_env("ARGUS_NO_CACHE", before),
        else: System.delete_env("ARGUS_NO_CACHE")
    end)
  end

  defp without_cache(fun) do
    System.put_env("ARGUS_NO_CACHE", "1")
    fun.()
  end

  test "ARGUS_NO_CACHE turns every store off, and only a set value does" do
    without_cache(fn ->
      refute Argus.Cache.enabled?()
      assert Argus.Cache.store(cache: "/anywhere") == nil
    end)

    for off <- ["", "0", "false"] do
      System.put_env("ARGUS_NO_CACHE", off)
      assert Argus.Cache.enabled?()
    end

    System.delete_env("ARGUS_NO_CACHE")
    assert Argus.Cache.enabled?()
  end

  test "a store option names a directory, and nothing else" do
    System.delete_env("ARGUS_NO_CACHE")
    assert Argus.Cache.store([]) == nil
    assert Argus.Cache.store(cache: "rel/store") == Path.expand("rel/store")
    assert_raise ArgumentError, fn -> Argus.Cache.store(cache: :yes) end
  end

  test "a solve under ARGUS_NO_CACHE is run and not kept", %{tmp_dir: tmp} do
    unless Souffle.available?(), do: flunk("souffle not installed")

    rules = Path.join(tmp, "p.dl")

    File.write!(rules, """
    .decl edge(x: symbol, y: symbol)
    .input edge
    .decl path(x: symbol, y: symbol)
    .output path
    path(x, y) :- edge(x, y).
    """)

    facts = Path.join(tmp, "facts")
    File.mkdir_p!(facts)
    File.write!(Path.join(facts, "edge.facts"), "a\tb\n")
    cache = Path.join(tmp, "solves")

    without_cache(fn ->
      assert {:ok, %{"path" => [["a", "b"]]}} = Souffle.run(facts, rules, solve_cache: cache)
    end)

    refute File.exists?(cache)
  end
end
