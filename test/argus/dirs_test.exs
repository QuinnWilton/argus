defmodule Argus.DirsTest do
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

  test "ARGUS_NO_CACHE keeps nothing, and only a set value does" do
    System.put_env("ARGUS_NO_CACHE", "1")
    refute Argus.Dirs.keep?()
    store = Argus.Graph.store()
    assert store.temporary?
    Roux.Blob.destroy(store)

    for off <- ["", "0", "false"] do
      System.put_env("ARGUS_NO_CACHE", off)
      assert Argus.Dirs.keep?()
    end

    System.delete_env("ARGUS_NO_CACHE")
    assert Argus.Dirs.keep?()
    refute Argus.Graph.store().temporary?
  end
end
