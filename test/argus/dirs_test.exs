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

  describe "cache directories" do
    use Argus.Test.Peer

    alias Argus.FlowLog.Toolchain
    alias Argus.Priors.Cache
    alias Argus.Test.Peer

    test "XDG_CACHE_HOME places them, and only when it is not empty" do
      Peer.run(Peer.start!(), fn ->
        System.delete_env("ARGUS_CACHE_DIR")
        home = System.user_home!()

        System.put_env("XDG_CACHE_HOME", "/xdg/cache")
        assert Argus.Dirs.cache_home() == "/xdg/cache"
        assert Argus.Graph.store_root() == "/xdg/cache/argus/store"
        assert Toolchain.root() == "/xdg/cache/argus/flowlog"
        # The priors stay where they always were.
        assert Cache.root() == Path.join(home, ".cache/argus/priors")

        System.put_env("XDG_CACHE_HOME", "")
        assert Argus.Graph.store_root() == Path.join(home, ".cache/argus/store")
      end)
    end

    @tag :tmp_dir
    test "a store that cannot be made leaves the run a temporary one, said once",
         %{tmp_dir: tmp} do
      locked = Path.join(tmp, "locked")
      File.mkdir_p!(locked)
      File.chmod!(locked, 0o500)
      on_exit(fn -> File.chmod(locked, 0o700) end)
      root = Path.join(locked, "store")

      Peer.run(Peer.start!(), fn ->
        System.put_env("ARGUS_CACHE_DIR", root)

        {stores, log} =
          ExUnit.CaptureLog.with_log(fn -> [Argus.Graph.store(), Argus.Graph.store()] end)

        assert Enum.all?(stores, & &1.temporary?)
        assert [_] = Regex.scan(~r/cannot keep its cache in #{root} \(permission denied\)/, log)
        Enum.each(stores, &Roux.Blob.destroy/1)
      end)
    end

    test "without a home, they go under the temporary directory, the user's own" do
      peer = Peer.start!(env: [{"HOME", nil}, {"XDG_CACHE_HOME", nil}])

      Peer.run(peer, fn ->
        System.delete_env("ARGUS_CACHE_DIR")
        assert System.user_home() in [nil, ""]

        base = Path.join(System.tmp_dir!(), "argus-#{Argus.Dirs.uid()}")
        assert Argus.Dirs.cache_home() == base
        assert Argus.Graph.store_root() == Path.join(base, "argus/store")
        assert Toolchain.root() == Path.join(base, "argus/flowlog")
        assert Cache.root() == Path.join(base, "argus/priors")

        # And they are usable: the store opens, owner-only.
        refute Argus.Graph.store().temporary?
        assert {:ok, _} = Toolchain.owned_dir("prebuilt")
      end)
    end
  end
end
