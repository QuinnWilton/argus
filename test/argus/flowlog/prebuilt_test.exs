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

  @unrunnable """
  #!/bin/sh
  echo run >> "${ARGUS_TEST_TOOL_RUNS:-/dev/null}"
  echo "Could not start dynamically linked executable: $0" >&2
  exit 127
  """

  setup_all do
    dir =
      Path.join(System.tmp_dir!(), "argus_prebuilt_test_#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf!(dir) end)

    # Stage 0's compiled engine, the one a release bundles.
    stage0 = Argus.Dl.path("stage0.dl")
    :ok = FlowLog.prebuild([stage0], progress: false)
    {:ok, %{kind: :compiled} = built} = FlowLog.engine(stage0, progress: false)
    engine = Program.executable(built.toolchain, built.digest)

    {:ok, offer_path} =
      Prebuilt.write_bundle(
        Toolchain.tool(built.toolchain),
        [{"stage0.dl", built.digest, engine, Path.join(Path.dirname(engine), "manifest.json")}],
        dir
      )

    offer = offer_path |> File.read!() |> :json.decode()

    # The same bundle, with a tool this machine cannot start: as one
    # linked for a generic Linux is to NixOS, whose stub loader says so
    # and exits 127.
    broken_tool = Path.join(dir, "broken-tool")
    File.write!(broken_tool, @unrunnable)
    File.chmod!(broken_tool, 0o755)

    {:ok, broken_path} =
      Prebuilt.write_bundle(
        broken_tool,
        [{"stage0.dl", built.digest, engine, Path.join(Path.dirname(engine), "manifest.json")}],
        Path.join(dir, "broken")
      )

    broken = broken_path |> File.read!() |> :json.decode()

    %{
      archive: Path.join(dir, offer["asset"]),
      offer: offer,
      broken: %{archive: Path.join([dir, "broken", broken["asset"]]), offer: broken},
      stage0: stage0,
      digest: built.digest
    }
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

  test "without Rust, argus's own programs solve from the bundle, and others in the generic engine",
       %{peer: peer, root: root, tmp_dir: tmp, stage0: stage0} = context do
    offer = offered(context)
    facts = empty_facts!(Path.join(tmp, "facts"), stage0)
    File.write!(Path.join(facts, "edge.facts"), "a\tb\nb\tc\n")
    custom = Path.join(tmp, "custom.dl")
    # The generic engine computes no averages: this program needs its own
    # engine built.
    unhosted = Path.join(tmp, "unhosted.dl")

    File.write!(custom, """
    .decl edge(a: symbol, b: symbol) mutable
    .input edge
    .decl node(a: symbol)
    .output node
    node(a) :- edge(a, _).
    """)

    File.write!(unhosted, """
    .decl edge(a: symbol, b: symbol) mutable
    .input edge
    .decl mean(n: number)
    .output mean
    mean(average(n)) :- edge(a, _), n = strlen(a).
    """)

    Peer.run(peer, fn ->
      System.put_env("ARGUS_FLOWLOG_DIR", root)
      System.put_env("ARGUS_CARGO", "/nonexistent/cargo")
      Application.put_env(:argus_beam, :flowlog_prebuilt, offer)

      assert FlowLog.available?()
      assert {:ok, %Toolchain{kind: :prebuilt, cargo: nil}} = Toolchain.ensure(progress: false)
      assert {:ok, results} = FlowLog.run(facts, stage0)
      assert is_map(results)

      # Not argus's own, so not bundled: the release's tool runs it.
      assert {:ok, %{"node" => [["a"], ["b"]]}} = FlowLog.run(facts, custom)

      # One the generic engine refuses needs Rust, and the reason names it.
      assert {:error, {:needs_rust, ^unhosted}} = FlowLog.run(facts, unhosted)
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
      # Nothing unpacked; the failure is kept, so the next run waits.
      assert File.ls!(Path.join(root, "prebuilt")) == [String.duplicate("0", 64) <> ".failed"]
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

      assert [failure] = File.ls!(Path.join(root, "prebuilt"))
      assert String.ends_with?(failure, ".failed")
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

  test "a bundle whose tool does not run here is not used, and the reason says why",
       %{peer: peer, root: root, broken: broken} do
    offer = offered(broken)

    Peer.run(peer, fn ->
      System.put_env("ARGUS_FLOWLOG_DIR", root)
      System.put_env("ARGUS_CARGO", "/nonexistent/cargo")
      Application.put_env(:argus_beam, :flowlog_prebuilt, offer)

      assert {:error, {:unrunnable, detail}} = Prebuilt.fetch(progress: false)
      assert detail =~ "exited 127: Could not start dynamically linked executable"

      assert {:error, {:no_engines, {:rust_missing, _}, {:unrunnable, _}}} =
               Toolchain.ensure(progress: false)

      refute FlowLog.available?()
      message = FlowLog.not_found_message()
      assert message =~ "ARGUS_CARGO names /nonexistent/cargo"
      assert message =~ "the prebuilt engines do not run on this machine"
      assert message =~ "nix-ld"
    end)
  end

  test "an installed tool that does not run here is replaced, with the engines beside it",
       %{peer: peer, root: root, stage0: stage0, digest: digest} = context do
    offer = offered(context)

    install = fn ->
      System.put_env("ARGUS_FLOWLOG_DIR", root)
      Application.put_env(:argus_beam, :flowlog_prebuilt, offer)
      assert {:ok, %Toolchain{kind: :rust} = toolchain} = Toolchain.ensure(progress: false)
      assert :ok = FlowLog.prebuild([stage0], progress: false)
      toolchain
    end

    toolchain = Peer.run(peer, install)
    File.write!(Toolchain.tool(toolchain), @unrunnable)
    engine = Program.executable(toolchain, digest)
    assert File.regular?(engine)

    # A VM that has not used the toolchain yet checks its tool.
    Peer.run(Peer.start!(), fn ->
      System.put_env("ARGUS_FLOWLOG_DIR", root)
      Application.put_env(:argus_beam, :flowlog_prebuilt, offer)

      {result, log} =
        ExUnit.CaptureLog.with_log(fn -> Toolchain.ensure(progress: false) end)

      assert {:ok, ^toolchain} = result
      assert log =~ "does not run on this machine (it exited 127"
      assert Toolchain.runs(Toolchain.tool(toolchain)) == :ok
      refute File.exists?(engine)

      assert :ok = FlowLog.prebuild([stage0], progress: false)
      assert File.regular?(engine)
    end)
  end

  test "with Rust, a bundle whose tool does not run here is tried once per VM, and quietly",
       %{peer: peer, root: root, broken: broken, stage0: stage0, tmp_dir: tmp} do
    offer = offered(broken)
    runs = Path.join(tmp, "tool-runs")

    # The suite's toolchain, built with Rust, but for its engines: no
    # engine of stage 0's is installed, so each lookup asks the bundle.
    {:ok, toolchain} = FlowLog.toolchain(progress: false)
    dir = Path.join(root, Path.basename(toolchain.dir))
    File.mkdir_p!(Path.join(dir, "engines"))

    for entry <- ~w(bin sources target logs crates),
        do: File.ln_s!(Path.join(toolchain.dir, entry), Path.join(dir, entry))

    Peer.run(peer, fn ->
      System.put_env("ARGUS_FLOWLOG_DIR", root)
      System.put_env("ARGUS_TEST_TOOL_RUNS", runs)
      Application.put_env(:argus_beam, :flowlog_prebuilt, offer)

      {engines, log} =
        ExUnit.CaptureLog.with_log(fn ->
          for _ <- 1..2, do: FlowLog.engine(stage0, progress: false)
        end)

      # Nothing is built in the bundle's place: stage 0 runs generically.
      assert [{:ok, %{kind: :generic}}, {:ok, %{kind: :generic}}] = engines
      refute log =~ "building the FlowLog engines instead"
      assert runs |> File.read!() |> String.split("\n", trim: true) == ["run"]
    end)
  end

  test "a cache root that is not the user's own is refused before anything in it runs",
       %{peer: peer, root: root, tmp_dir: tmp, broken: broken} do
    offer = offered(broken)
    runs = Path.join(tmp, "tool-runs")

    # A bundle unpacked where argus would look for it, in a directory the
    # root only links to.
    elsewhere = Path.join(tmp, "elsewhere")
    planted = Path.join([elsewhere, "prebuilt", broken.offer["sha256"]])
    tool = Path.join([planted, "bin", "argus-flowlog-tool"])
    File.mkdir_p!(Path.dirname(tool))
    File.write!(Path.join(planted, "bundle.json"), "{}")
    File.write!(tool, @unrunnable)
    File.chmod!(tool, 0o755)
    File.rm_rf!(root)
    File.ln_s!(elsewhere, root)

    Peer.run(peer, fn ->
      System.put_env("ARGUS_FLOWLOG_DIR", root)
      System.put_env("ARGUS_CARGO", "/nonexistent/cargo")
      System.put_env("ARGUS_TEST_TOOL_RUNS", runs)
      Application.put_env(:argus_beam, :flowlog_prebuilt, offer)

      assert {:error, {:untrusted_root, ^root, detail}} = Prebuilt.fetch(progress: false)
      assert detail =~ "symlink"

      assert {:error, {:untrusted_root, ^root, _}} = Toolchain.ensure(progress: false)
      refute File.exists?(runs)
    end)
  end

  test "a failed download is not tried again for an hour",
       %{peer: peer, root: root, tmp_dir: tmp, archive: archive, offer: offer} do
    later = Path.join(tmp, "later.tar.gz")
    offered = offering(later, offer["sha256"], offer["bytes"])
    failure = Path.join([root, "prebuilt", offer["sha256"] <> ".failed"])

    Peer.run(peer, fn ->
      System.put_env("ARGUS_FLOWLOG_DIR", root)
      Application.put_env(:argus_beam, :flowlog_prebuilt, offered)

      assert {:error, {:download_failed, _, :enoent}} = Prebuilt.fetch(progress: false)

      # The bundle is there now, but the failure stands.
      File.cp!(archive, later)

      assert {:error, {:recently_failed, "file://" <> _, age, detail} = reason} =
               Prebuilt.fetch(progress: false)

      assert age < 60
      assert detail =~ "failed: :enoent"
      assert Prebuilt.describe(reason) =~ "tries again an hour after"

      # An hour on, it is tried again, and the failure goes.
      File.touch!(failure, System.os_time(:second) - 3600)
      assert {:ok, _dir} = Prebuilt.fetch(progress: false)
      refute File.exists?(failure)
    end)
  end

  test "forgotten, a failed download is tried at once; another release's failure is stale",
       %{peer: peer, root: root, tmp_dir: tmp, archive: archive, offer: offer} do
    later = Path.join(tmp, "later.tar.gz")
    offered = offering(later, offer["sha256"], offer["bytes"])
    other = Path.join([root, "prebuilt", String.duplicate("f", 64) <> ".failed"])

    Peer.run(peer, fn ->
      System.put_env("ARGUS_FLOWLOG_DIR", root)
      Application.put_env(:argus_beam, :flowlog_prebuilt, offered)

      assert {:error, {:download_failed, _, :enoent}} = Prebuilt.fetch(progress: false)
      File.write!(other, "another release's")
      assert Prebuilt.stale() == [other]

      File.cp!(archive, later)
      assert :ok = Prebuilt.forget_failures()
      refute File.exists?(other)
      assert {:ok, _dir} = Prebuilt.fetch(progress: false)
    end)
  end

  test "offline, a bundle is used once downloaded, and none is downloaded",
       %{peer: peer, root: root} = context do
    offer = offered(context)
    sha = context.offer["sha256"]

    Peer.run(peer, fn ->
      System.put_env("ARGUS_FLOWLOG_DIR", root)
      Application.put_env(:argus_beam, :flowlog_prebuilt, offer)
      System.put_env("ARGUS_OFFLINE", "1")

      assert {:error, :offline} = Prebuilt.fetch(progress: false)
      assert Prebuilt.describe(:offline) =~ "offline"
      # Nothing fetched, and nothing kept as a failure.
      assert File.ls!(Path.join(root, "prebuilt")) == []

      System.delete_env("ARGUS_OFFLINE")
      assert {:ok, dir} = Prebuilt.fetch(progress: false)
      System.put_env("ARGUS_OFFLINE", "1")
      assert {:ok, ^dir} = Prebuilt.fetch(progress: false)
      assert Path.basename(dir) == sha
    end)
  end
end
