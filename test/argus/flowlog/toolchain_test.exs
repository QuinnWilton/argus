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

  alias Argus.FlowLog.{Prebuilt, Toolchain}
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

  test "offline, Cargo builds without fetching", %{peer: peer, tmp_dir: tmp} do
    args = Path.join(tmp, "args")
    cargo = Path.join(tmp, "cargo")
    File.write!(cargo, "#!/bin/sh\necho \"$*\" >> \"#{args}\"\n")
    File.chmod!(cargo, 0o755)
    crate = Path.join(tmp, "crate")
    File.mkdir_p!(crate)

    toolchain = %Toolchain{
      dir: tmp,
      key: "test",
      kind: :rust,
      cargo: cargo,
      rustc: cargo,
      rustc_version: ""
    }

    Peer.run(peer, fn ->
      log = Path.join(tmp, "build.log")
      assert :ok = Toolchain.cargo_build(toolchain, crate, ["tool"], log, :tool)
      System.put_env("ARGUS_OFFLINE", "1")
      assert :ok = Toolchain.cargo_build(toolchain, crate, ["tool"], log, :tool)
    end)

    assert [online, offline] = args |> File.read!() |> String.split("\n", trim: true)
    refute online =~ "--offline"
    assert offline =~ "--offline"
  end

  test "a build of the tool that fails is tried once per VM, however many ask, and says why first",
       %{peer: peer, tmp_dir: tmp} do
    runs = Path.join(tmp, "cargo-runs")
    bin = Path.join(tmp, "bin")
    File.mkdir_p!(bin)

    # A Rust whose builds fail as they do without a C compiler: one cause,
    # and a consequence per crate.
    File.write!(Path.join(bin, "cargo"), """
    #!/bin/sh
    echo run >> "#{runs}"
    sleep 0.3
    echo "error: linker \\`cc\\` not found"
    for crate in quote serde libc; do
      echo "error: could not compile \\`$crate\\` (build script) due to 1 previous error"
    done
    exit 101
    """)

    File.write!(Path.join(bin, "rustc"), "#!/bin/sh\necho 'release: 1.90.0'\n")
    for exe <- ~w(cargo rustc), do: File.chmod!(Path.join(bin, exe), 0o755)

    Peer.run(peer, fn ->
      System.put_env("ARGUS_FLOWLOG_DIR", Path.join(tmp, "root"))
      System.put_env("ARGUS_CARGO", Path.join(bin, "cargo"))
      System.put_env("ARGUS_FLOWLOG_PREBUILT", "0")

      # Every analysis of a run asks at once.
      assert [{:error, {:build_failed, :tool, _log, tail} = reason} | others] =
               1..3
               |> Task.async_stream(fn _ -> Toolchain.ensure(progress: false) end)
               |> Enum.map(fn {:ok, result} -> result end)

      assert Enum.all?(others, &(&1 == {:error, reason}))

      assert tail =~ ~r/\Aerror: linker `cc` not found\n\(and 3 crate\(s\) could not compile\)\n/
      assert Toolchain.describe(reason) =~ "install gcc or clang"

      assert {:error, ^reason} = Toolchain.ensure(progress: false)
      assert File.read!(runs) == "run\n"

      assert :ok = Toolchain.forget_failures()
      assert {:error, {:build_failed, :tool, _, _}} = Toolchain.ensure(progress: false)
      assert File.read!(runs) == "run\nrun\n"
    end)
  end

  describe "why there are no engines" do
    @url "https://example.com/argus-flowlog.tar.gz"

    test "a bundle that could not be used comes first, and Rust as the other way" do
      failed =
        {:recently_failed, @url, 90,
         "cannot connect to github.com:443: non-existing domain (nxdomain)"}

      message =
        Toolchain.describe({:no_engines, {:rust_missing, "cargo was not found on PATH"}, failed})

      assert message =~
               ~r/^argus runs its analyses on FlowLog engines, and could not use the prebuilt/

      assert message =~ "failed a minute ago (cannot connect to github.com:443"
      assert message =~ "with Rust 1.88.0 or newer, and cargo was not found on PATH: install"
      assert length(String.split(message, @url)) == 2
    end

    test "without a bundle to use, Rust comes first" do
      for reason <- [:disabled, :none, {:no_bundle, "riscv64gc-unknown-linux-gnu"}] do
        message =
          Toolchain.describe({:no_engines, {:rust_too_old, "1.70.0", "1.88.0"}, reason})

        assert message =~ ~r/^argus builds its FlowLog engines with Rust 1.88.0 or newer/
        assert message =~ "prebuilt engines are no help either"
      end
    end

    @tag :tmp_dir
    test "a tool too new for this system's glibc says which glibc it needs", %{tmp_dir: tmp} do
      tool = Path.join(tmp, "tool")

      # As the dynamic loader of a system with glibc 2.31 says it.
      File.write!(tool, """
      #!/bin/sh
      for v in 2.33 2.4 2.34 2.32; do
        echo "$0: /lib/libc.so.6: version \\`GLIBC_$v' not found (required by $0)" >&2
      done
      exit 1
      """)

      File.chmod!(tool, 0o755)

      assert {:error, detail} = Toolchain.runs(tool)
      assert detail == "it needs glibc 2.34 or newer, and this system's is older"

      message = Prebuilt.describe({:unrunnable, detail})
      assert message =~ "do not run on this machine (the bundle's tool: it needs glibc 2.34"
      refute message =~ "nix-ld"
    end

    @tag :tmp_dir
    test "a tool whose dynamic loader this system lacks names the loader", %{tmp_dir: tmp} do
      loader = "/nonexistent/ld-linux-aarch64.so.1"
      interp = loader <> <<0>>

      # The headers of a 64-bit ELF executable, as NixOS sees one linked for
      # other Linux distributions: a PT_INTERP naming a loader it does not have.
      elf =
        <<0x7F, "ELF", 2, 1, 1, 0::size(9)-unit(8), 2::little-16, 0xB7::little-16, 1::little-32,
          0::little-64, 64::little-64, 0::little-64, 0::little-32, 64::little-16, 56::little-16,
          1::little-16, 0::little-16, 0::little-16, 0::little-16>> <>
          <<3::little-32, 4::little-32, 120::little-64, 0::little-64, 0::little-64,
            byte_size(interp)::little-64, byte_size(interp)::little-64, 1::little-64>> <>
          interp

      tool = Path.join(tmp, "tool")
      File.write!(tool, elf)
      File.chmod!(tool, 0o755)

      assert Toolchain.runs(tool) ==
               {:error, "its dynamic loader, #{loader}, is not on this system"}
    end

    test "a failed download says what went wrong in words" do
      connect =
        {:failed_connect, [{:to_address, {~c"github.com", 443}}, {:inet, [:inet], :nxdomain}]}

      assert Prebuilt.describe({:download_failed, @url, connect}) ==
               "downloading #{@url} failed: cannot connect to github.com:443: " <>
                 "non-existing domain (nxdomain)"

      assert Prebuilt.describe({:download_failed, @url, {:http, 404}}) =~
               "failed: the server answered HTTP 404"

      assert Prebuilt.describe({:download_failed, @url, {:weird, 1}}) =~
               "failed: {:weird, 1}"
    end
  end
end
