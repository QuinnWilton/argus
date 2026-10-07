defmodule Argus.FlowLog.PrebuiltTest do
  @moduledoc """
  A release's bundle of prebuilt engines (`Argus.FlowLog.Prebuilt`): a
  machine without Rust solves argus's own programs from it, one with
  Rust builds none of them, and a bundle that fails a check (its
  SHA-256, an entry out of place) is refused before anything in it is
  used.

  The bundles here hold stage 0's engine, built by this suite's
  toolchain, and are offered through the application env with `file://`
  URLs. Each test runs in a peer (`Argus.Test.Peer`): the cache root,
  `ARGUS_CARGO` and the offer are VM-wide.
  """
  use ExUnit.Case, async: true
  use Argus.Test.Peer

  alias Argus.FlowLog
  alias Argus.FlowLog.{Native, Prebuilt, Program, Toolchain}
  alias Argus.Test.Peer

  @moduletag :flowlog
  @moduletag :tmp_dir

  setup_all do
    dir =
      Path.join(System.tmp_dir!(), "argus_prebuilt_test_#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf!(dir) end)

    stage0 = Argus.Dl.path("stage0.dl")
    {:ok, built} = FlowLog.engine(stage0, progress: false)
    engine = Program.executable(built.toolchain, built.digest)

    {:ok, offer_path} =
      Prebuilt.write_bundle(
        Toolchain.tool(built.toolchain),
        [{"stage0.dl", built.digest, engine, Path.join(Path.dirname(engine), "manifest.json")}],
        dir
      )

    offer = offer_path |> File.read!() |> :json.decode()
    %{archive: Path.join(dir, offer["asset"]), offer: offer, stage0: stage0, digest: built.digest}
  end

  setup %{tmp_dir: tmp} do
    root = Path.join(tmp, "cache")
    File.mkdir_p!(root)
    File.chmod!(root, 0o700)
    %{peer: Peer.start!(), root: root}
  end

  defp offering(archive, sha, bytes) do
    %{
      "format" => 1,
      "native" => Native.digest(),
      "bundles" => %{
        elem(Prebuilt.platform(), 1) => %{
          "url" => "file://" <> archive,
          "sha256" => sha,
          "bytes" => bytes
        }
      }
    }
  end

  defp offered(%{archive: archive, offer: offer}),
    do: offering(archive, offer["sha256"], offer["bytes"])

  # Every input stage 0 reads, empty: enough for its engine to answer.
  defp empty_facts!(dir, program) do
    File.mkdir_p!(dir)
    {:ok, files} = FlowLog.input_files(program)
    for file <- files, do: File.write!(Path.join(dir, file), "")
    dir
  end

  defp sha256(path), do: :crypto.hash(:sha256, File.read!(path)) |> Base.encode16(case: :lower)

  test "without Rust, argus's own programs solve from the bundle, and others say Rust is needed",
       %{peer: peer, root: root, tmp_dir: tmp, stage0: stage0} = context do
    offer = offered(context)
    facts = empty_facts!(Path.join(tmp, "facts"), stage0)
    custom = Path.join(tmp, "custom.dl")

    File.write!(custom, """
    .decl edge(a: symbol, b: symbol) mutable
    .input edge
    .decl node(a: symbol)
    .output node
    node(a) :- edge(a, _).
    """)

    Peer.run(peer, fn ->
      System.put_env("ARGUS_FLOWLOG_DIR", root)
      System.put_env("ARGUS_CARGO", "/nonexistent/cargo")
      Application.put_env(:argus_beam, :flowlog_prebuilt, offer)

      assert {:ok, %Toolchain{kind: :prebuilt, cargo: nil}} = Toolchain.ensure(progress: false)
      assert {:ok, results} = FlowLog.run(facts, stage0)
      assert is_map(results)

      # Not argus's own, so not bundled: the reason names it.
      assert {:error, {:needs_rust, ^custom}} = FlowLog.run(facts, custom)
    end)
  end

  test "with Rust, the tool and the bundled engines are installed, never compiled",
       %{peer: peer, root: root, stage0: stage0, digest: digest} = context do
    offer = offered(context)

    Peer.run(peer, fn ->
      System.put_env("ARGUS_FLOWLOG_DIR", root)
      Application.put_env(:argus_beam, :flowlog_prebuilt, offer)

      assert {:ok, %Toolchain{kind: :rust} = toolchain} = Toolchain.ensure(progress: false)
      assert :ok = FlowLog.prebuild([stage0], progress: false)
      assert File.regular?(Program.executable(toolchain, digest))
      # Nothing was built: Cargo wrote no log, and no target directory.
      assert Path.wildcard(Path.join(Toolchain.logs(toolchain), "*.log")) == []
      refute File.exists?(Toolchain.target(toolchain))
    end)
  end

  test "a bundle whose SHA-256 is not the one offered is refused, and nothing is unpacked",
       %{peer: peer, root: root, archive: archive, offer: offer} do
    wrong = offering(archive, String.duplicate("0", 64), offer["bytes"])

    Peer.run(peer, fn ->
      System.put_env("ARGUS_FLOWLOG_DIR", root)
      Application.put_env(:argus_beam, :flowlog_prebuilt, wrong)

      assert {:error, {:checksum_mismatch, _, actual}} = Prebuilt.fetch(progress: false)
      assert actual == offer["sha256"]
      assert File.ls!(Path.join(root, "prebuilt")) == []
    end)
  end

  test "a bundle holding anything out of place is refused before it is unpacked",
       %{peer: peer, root: root, tmp_dir: tmp} do
    stray = Path.join(tmp, "stray")
    File.write!(stray, "not argus's")
    File.write!(Path.join(tmp, "bundle.json"), "{}")
    bad = Path.join(tmp, "bad.tar.gz")

    :ok =
      :erl_tar.create(
        String.to_charlist(bad),
        [
          {~c"bundle.json", String.to_charlist(Path.join(tmp, "bundle.json"))},
          {~c"bin/../../escaped", String.to_charlist(stray)}
        ],
        [:compressed]
      )

    offer = offering(bad, sha256(bad), File.stat!(bad).size)

    Peer.run(peer, fn ->
      System.put_env("ARGUS_FLOWLOG_DIR", root)
      Application.put_env(:argus_beam, :flowlog_prebuilt, offer)

      assert {:error, {:bad_bundle, "unexpected bin/../../escaped"}} =
               Prebuilt.fetch(progress: false)

      assert File.ls!(Path.join(root, "prebuilt")) == []
      refute File.exists?(Path.join(root, "escaped"))
    end)
  end

  test "turned off, no bundle is offered", %{peer: peer, root: root} = context do
    offer = offered(context)

    Peer.run(peer, fn ->
      System.put_env("ARGUS_FLOWLOG_DIR", root)
      System.put_env("ARGUS_FLOWLOG_PREBUILT", "0")
      Application.put_env(:argus_beam, :flowlog_prebuilt, offer)

      assert {:error, :disabled} = Prebuilt.fetch(progress: false)
      refute File.exists?(Path.join(root, "prebuilt"))
    end)
  end

  test "an offer for other toolchain sources is not used", %{peer: peer, root: root} = context do
    offer = %{offered(context) | "native" => String.duplicate("f", 64)}

    Peer.run(peer, fn ->
      System.put_env("ARGUS_FLOWLOG_DIR", root)
      Application.put_env(:argus_beam, :flowlog_prebuilt, offer)
      assert {:error, {:other_sources, _}} = Prebuilt.offer()
    end)
  end
end
