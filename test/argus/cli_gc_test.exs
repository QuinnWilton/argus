defmodule Argus.CLIGcTest do
  @moduledoc """
  `argus gc` collects the blob store the environment names, and the rule
  trees other builds unpacked there.
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
    File.touch!(Roux.Blob.path(blob, digest), System.os_time(:second) - 60)

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
end
