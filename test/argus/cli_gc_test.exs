defmodule Argus.CLIGcTest do
  @moduledoc """
  `argus gc` collects the blob store the environment names, and the rule
  trees other builds unpacked there; a store another user could have
  written is refused, and the rules are never unpacked into a root the
  store did not make.
  """

  # ARGUS_CACHE_DIR is VM-wide.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    previous = System.get_env("ARGUS_CACHE_DIR")
    store = Path.join(dir, "store")
    System.put_env("ARGUS_CACHE_DIR", store)

    on_exit(fn ->
      if previous,
        do: System.put_env("ARGUS_CACHE_DIR", previous),
        else: System.delete_env("ARGUS_CACHE_DIR")
    end)

    %{store: store}
  end

  test "no store is nothing to collect", %{store: store} do
    output = capture_io(fn -> assert Argus.CLI.run(["gc"]) == 0 end)
    assert output == "argus gc: #{store}: nothing to collect\n"
  end

  test "an unretained entry past its grace goes; another build's rules go", %{store: store} do
    {:ok, blob} = Roux.Blob.open(store)
    {:ok, digest} = Roux.Blob.put(blob, "an entry nothing retains")
    # Past the store's refresh interval (an hour), which a collection's
    # grace is never shorter than.
    File.touch!(Roux.Blob.path(blob, digest), System.os_time(:second) - 2 * 60 * 60)

    old = Path.join([store, "dl", String.duplicate("0", 64)])
    File.mkdir_p!(old)
    File.touch!(old, System.os_time(:second) - 2 * 24 * 60 * 60)
    current = Argus.Dl.Embedded.unpack!(Path.join(store, "dl"))

    output = capture_io(fn -> assert Argus.CLI.run(["gc", "--grace", "0"]) == 0 end)

    assert output =~ "removed 1 ("
    assert output =~ "removed 1 unpacked rule trees of other versions"
    refute Roux.Blob.member?(blob, digest)
    refute File.exists?(old)
    assert File.dir?(current)
  end

  test "a store its group can write is refused, saying how to fix it", %{store: store} do
    {:ok, _blob} = Roux.Blob.open(store)
    File.chmod!(store, 0o775)

    stderr =
      capture_io(:stderr, fn ->
        _stdout = capture_io(fn -> assert Argus.CLI.run(["gc"]) == 3 end)
      end)

    assert stderr =~ "refusing the blob store at #{store}"
    assert stderr =~ "chmod go-w #{store}"
  end

  test "the rules' directory is under a store root the store made", %{store: store} do
    refute File.exists?(store)
    assert Argus.Dirs.dl() == Path.join(store, "dl")
    assert %File.Stat{mode: mode} = File.stat!(store)
    assert Bitwise.band(mode, 0o777) == 0o700
    assert File.regular?(Path.join(store, "FORMAT"))
  end
end
