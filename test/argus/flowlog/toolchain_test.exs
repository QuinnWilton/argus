defmodule Argus.FlowLog.ToolchainTest do
  @moduledoc """
  What `mix argus.flowlog clean` removes (`Argus.FlowLog.Toolchain.stale/1`):
  toolchains of other sources or another Rust, never the current one, and
  nothing else a cache root holds, wherever `ARGUS_FLOWLOG_DIR` points.

  In a peer (`Argus.Test.Peer`): `ARGUS_FLOWLOG_DIR` is VM-wide.
  """
  use ExUnit.Case, async: true
  use Argus.Test.Peer

  alias Argus.FlowLog.Toolchain
  alias Argus.Test.Peer

  @moduletag :tmp_dir

  setup do
    %{peer: Peer.start!()}
  end

  defp toolchain!(root, name) do
    for sub <- ~w(engines sources), do: File.mkdir_p!(Path.join([root, name, sub]))
    Path.join(root, name)
  end

  test "lists toolchains other than the current one, and nothing else", %{
    peer: peer,
    tmp_dir: tmp
  } do
    current = String.duplicate("c", 24)
    old = toolchain!(tmp, String.duplicate("a", 24))
    older = toolchain!(tmp, String.duplicate("b", 24))
    _ = toolchain!(tmp, current)
    # Shaped like a toolchain's name, but not made by one.
    File.mkdir_p!(Path.join(tmp, String.duplicate("d", 24)))
    # A user's own directory, toolchain-shaped inside.
    _ = toolchain!(tmp, "notes")
    File.write!(Path.join(tmp, String.duplicate("e", 24)), "a file")

    Peer.run(peer, fn ->
      System.put_env("ARGUS_FLOWLOG_DIR", tmp)
      assert Toolchain.stale(current) == [old, older]
      assert Toolchain.stale(nil) == [old, older, Path.join(tmp, current)]
    end)
  end

  test "a root that does not exist holds no toolchain", %{peer: peer, tmp_dir: tmp} do
    Peer.run(peer, fn ->
      System.put_env("ARGUS_FLOWLOG_DIR", Path.join(tmp, "absent"))
      assert Toolchain.stale(nil) == []
    end)
  end
end
