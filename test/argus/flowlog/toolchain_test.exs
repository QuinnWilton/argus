defmodule Argus.FlowLog.ToolchainTest do
  @moduledoc """
  What `mix argus.flowlog clean` removes (`Argus.FlowLog.Toolchain.stale/1`):
  toolchains of other sources or another Rust, never the current one, and
  nothing else a cache root holds, wherever `ARGUS_FLOWLOG_DIR` points. And
  that a build stops with the VM running it.

  In a peer (`Argus.Test.Peer`): `ARGUS_FLOWLOG_DIR` is VM-wide, and the
  build's VM is stopped.
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

  defp alive?(pid), do: match?({_, 0}, System.cmd("kill", ["-0", pid], stderr_to_stdout: true))

  defp eventually(fun, tries \\ 100) do
    cond do
      fun.() -> true
      tries == 0 -> false
      true -> Process.sleep(50) && eventually(fun, tries - 1)
    end
  end

  test "a build stops, with the compilers it started, when the VM running it does",
       %{peer: peer, tmp_dir: tmp} do
    # A `cargo` that starts a compiler and waits on it.
    pidfile = Path.join(tmp, "compiler.pid")
    cargo = Path.join(tmp, "cargo")
    File.write!(cargo, "#!/bin/sh\nsleep 600 &\necho $! > '#{pidfile}'\nwait\n")
    File.chmod!(cargo, 0o755)
    crate = Path.join(tmp, "crate")
    File.mkdir_p!(crate)

    toolchain = %Toolchain{
      dir: tmp,
      key: "test",
      kind: :rust,
      cargo: cargo,
      rustc: "rustc",
      rustc_version: "0"
    }

    Peer.run(peer, fn ->
      spawn(fn ->
        Toolchain.cargo_build(toolchain, crate, [], Path.join(tmp, "build.log"), :test)
      end)

      :ok
    end)

    assert eventually(fn -> File.exists?(pidfile) and File.read!(pidfile) != "" end)
    compiler = pidfile |> File.read!() |> String.trim()
    assert alive?(compiler)

    :peer.stop(peer)
    assert eventually(fn -> not alive?(compiler) end)
  end
end
