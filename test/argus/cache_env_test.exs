defmodule Argus.CacheEnvTest do
  # Sync on purpose: ARGUS_NO_CACHE is read from the VM-wide environment,
  # and a concurrent test would find its store turned off under it.
  use ExUnit.Case, async: false

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
end
