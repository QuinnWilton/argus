defmodule Argus.TestStoreTest do
  @moduledoc """
  The suite's store lives under the user's cache, in a directory of the
  checkout's own, and goes when the checkout's build does.
  """

  use ExUnit.Case, async: true
  use Argus.Test.Peer

  alias Argus.Test.{Peer, Store}

  @moduletag :tmp_dir

  # A peer whose cache is `tmp`'s: the environment is VM-wide.
  defp peer(tmp, env \\ []),
    do: Peer.start!(env: [{"XDG_CACHE_HOME", Path.join(tmp, "cache")} | env])

  test "is a directory of the checkout's own under the cache, saying whose", %{tmp_dir: tmp} do
    {root, build, cwd} =
      Peer.run(peer(tmp, [{"ARGUS_TEST_STORE", nil}]), fn ->
        {Store.root(), Path.expand(Mix.Project.build_path()), File.cwd!()}
      end)

    dir = Path.dirname(root)
    assert Path.basename(root) == "store"
    assert Path.dirname(dir) == Path.join(tmp, "cache/argus/test")
    assert Path.basename(dir) =~ ~r/\A#{Regex.escape(Path.basename(cwd))}-[0-9a-f]{12}\z/
    assert File.read!(Path.join(dir, "checkout")) == build
  end

  test "ARGUS_TEST_STORE names it instead", %{tmp_dir: tmp} do
    root = Path.join(tmp, "elsewhere/store")
    assert Peer.run(peer(tmp, [{"ARGUS_TEST_STORE", root}]), &Store.root/0) == root
    refute File.exists?(Path.join(tmp, "cache"))
  end

  test "tmp/ is linked into the checkout's directory, once, and not in CI", %{tmp_dir: tmp} do
    work = Path.join(tmp, "work")
    File.mkdir_p!(work)

    {first, again, root} =
      Peer.run(peer(tmp, [{"ARGUS_TEST_STORE", nil}]), fn ->
        File.cd!(work)
        {Store.link_tmp(), Store.link_tmp(), Store.root()}
      end)

    assert {first, again} == {:linked, :kept}
    assert File.read_link!(Path.join(work, "tmp")) == Path.join(Path.dirname(root), "tmp")
    assert File.dir?(Path.join(work, "tmp"))

    ci = Path.join(tmp, "ci")
    File.mkdir_p!(ci)

    assert Peer.run(peer(tmp, [{"ARGUS_TEST_STORE", Path.join(tmp, "s")}]), fn ->
             File.cd!(ci)
             Store.link_tmp()
           end) == :skipped

    refute File.exists?(Path.join(ci, "tmp"))
  end

  test "the stores of checkouts whose build is gone are removed", %{tmp_dir: tmp} do
    base = Path.join(tmp, "cache/argus/test")
    live = Path.join(tmp, "live/_build/test")
    File.mkdir_p!(live)

    dirs =
      for {name, checkout} <- [
            live: live,
            gone: Path.join(tmp, "gone/_build/test"),
            unsaid: nil
          ],
          into: %{} do
        dir = Path.join(base, "#{name}-000000000000")
        File.mkdir_p!(Path.join(dir, "store"))
        if checkout, do: File.write!(Path.join(dir, "checkout"), checkout)
        {name, dir}
      end

    assert Peer.run(peer(tmp), &Store.prune_orphans/0) == [dirs.gone]
    refute File.exists?(dirs.gone)
    assert File.dir?(Path.join(dirs.live, "store"))
    assert File.dir?(Path.join(dirs.unsaid, "store"))
  end
end
