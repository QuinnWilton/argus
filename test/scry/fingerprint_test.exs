defmodule Scry.FingerprintTest do
  # The souffle_version tests move PATH, which is VM-wide: they run in
  # this module's peer (`Scry.Test.Peer`), and the module runs async.
  use ExUnit.Case, async: true
  use Scry.Test.Peer

  alias Scry.Test.Peer

  @moduletag :tmp_dir

  # A souffle that prints the real banner shape: a rule of dashes first,
  # the version on the line after it.
  defp fake_souffle!(dir, version, word_size \\ 64) do
    path = Path.join(dir, "souffle")

    File.write!(path, """
    #!/bin/sh
    cat <<'BANNER'
    ----------------------------------------------------------------------------
    Version: #{version}
    Word size: #{word_size} bits
    Options enabled: ffi ncurses sqlite zlib
    ----------------------------------------------------------------------------
    Copyright (c) 2016-25 The Souffle Developers.
    BANNER
    """)

    File.chmod!(path, 0o755)
  end

  # `fun` in the peer, with `dir` first on its PATH.
  defp with_path(peer, dir, fun) do
    Peer.run(peer, fn ->
      original = System.get_env("PATH")
      System.put_env("PATH", dir <> ":" <> original)

      try do
        fun.()
      after
        System.put_env("PATH", original)
      end
    end)
  end

  describe "souffle_version/0" do
    setup do
      %{peer: Peer.start!()}
    end

    test "records the solver's version, not the banner's rule", %{tmp_dir: dir, peer: peer} do
      fake_souffle!(dir, "2.5")

      assert with_path(peer, dir, fn -> Scry.Fingerprint.souffle_version() end) ==
               "2.5 (64-bit words)"
    end

    test "moves when the version or the word size does", %{tmp_dir: dir, peer: peer} do
      fake_souffle!(dir, "2.5")
      old = with_path(peer, dir, fn -> Scry.Fingerprint.rules([:mailbox]) end)

      fake_souffle!(dir, "2.6")
      new = with_path(peer, dir, fn -> Scry.Fingerprint.rules([:mailbox]) end)
      assert old.mailbox != new.mailbox
      assert old.stage0 != new.stage0

      fake_souffle!(dir, "2.6", 32)
      assert with_path(peer, dir, fn -> Scry.Fingerprint.rules([:mailbox]) end) != new
    end

    test "fingerprints an unfamiliar banner whole", %{tmp_dir: dir, peer: peer} do
      path = Path.join(dir, "souffle")
      File.write!(path, "#!/bin/sh\necho 'souffle nightly abc123'\n")
      File.chmod!(path, 0o755)
      nightly = with_path(peer, dir, fn -> Scry.Fingerprint.souffle_version() end)

      File.write!(path, "#!/bin/sh\necho 'souffle nightly def456'\n")
      assert nightly =~ "unrecognized:"
      assert with_path(peer, dir, fn -> Scry.Fingerprint.souffle_version() end) != nightly
    end

    test "is unknown without a solver", %{tmp_dir: dir, peer: peer} do
      # PATH narrowed to a directory with no souffle in it.
      Peer.run(peer, fn ->
        System.put_env("PATH", dir)
        assert Scry.Fingerprint.souffle_version() == "unknown"
      end)
    end
  end

  describe "program_digest/1" do
    # analyses/a.dl → ../lib/shared.dl → deep.dl; analyses/b.dl stands
    # alone; lib/unrelated.dl is included by nothing.
    defp rules_tree!(dir) do
      File.mkdir_p!(Path.join(dir, "analyses"))
      File.mkdir_p!(Path.join(dir, "lib"))

      File.write!(
        Path.join(dir, "analyses/a.dl"),
        ~s(.include "../lib/shared.dl"\n.decl a\(x: symbol\)\n)
      )

      File.write!(Path.join(dir, "analyses/b.dl"), ".decl b(x: symbol)\n")

      File.write!(
        Path.join(dir, "lib/shared.dl"),
        ~s(  .include "deep.dl"\n.decl s\(x: symbol\)\n)
      )

      File.write!(Path.join(dir, "lib/deep.dl"), ".decl d(x: symbol)\n")
      File.write!(Path.join(dir, "lib/unrelated.dl"), ".decl u(x: symbol)\n")
    end

    defp digests(dir) do
      {Scry.Fingerprint.program_digest(Path.join(dir, "analyses/a.dl")),
       Scry.Fingerprint.program_digest(Path.join(dir, "analyses/b.dl"))}
    end

    test "moves with a transitively included file, only for its includers", %{tmp_dir: dir} do
      rules_tree!(dir)
      {a, b} = digests(dir)

      File.write!(Path.join(dir, "lib/deep.dl"), ".decl d(x: symbol, y: symbol)\n")
      {a2, b2} = digests(dir)
      assert a2 != a
      assert b2 == b

      File.write!(Path.join(dir, "lib/unrelated.dl"), ".decl u(x: number)\n")
      assert digests(dir) == {a2, b2}
    end

    test "a missing include moves the digest when it appears", %{tmp_dir: dir} do
      rules_tree!(dir)
      File.rm!(Path.join(dir, "lib/deep.dl"))
      {missing, _} = digests(dir)

      File.write!(Path.join(dir, "lib/deep.dl"), "")
      assert elem(digests(dir), 0) != missing
    end

    test "the shipped programs digest, and differ per analysis" do
      digests = Scry.Fingerprint.rules([:mailbox, :coupling])
      assert Map.keys(digests) |> Enum.sort() == [:coupling, :mailbox, :points_to, :stage0]
      assert digests.mailbox != digests.coupling
    end
  end

  describe "code_digest/1" do
    test "moves when a beam's content does", %{tmp_dir: dir} do
      File.write!(Path.join(dir, "Elixir.A.beam"), "one")
      File.write!(Path.join(dir, "Elixir.B.beam"), "two")
      before = Scry.Fingerprint.code_digest(dir)

      File.write!(Path.join(dir, "Elixir.B.beam"), "three")
      assert Scry.Fingerprint.code_digest(dir) != before
    end

    test "a rebuild whose type checker table differs digests the same", %{tmp_dir: dir} do
      # Compiling the same source again beside other code can write a
      # different `ExCk` chunk; the code is the same.
      source = :code.which(Scry.Fingerprint)
      {:ok, _module, chunks} = :beam_lib.all_chunks(source)
      assert List.keymember?(chunks, ~c"ExCk", 0)

      write = fn chunks ->
        {:ok, beam} = :beam_lib.build_module(chunks)
        File.write!(Path.join(dir, "Elixir.Scry.Fingerprint.beam"), beam)
        Scry.Fingerprint.code_digest(dir)
      end

      original = write.(chunks)
      assert write.(List.keyreplace(chunks, ~c"ExCk", 0, {~c"ExCk", "rebuilt"})) == original

      {~c"Code", code} = List.keyfind(chunks, ~c"Code", 0)
      refute write.(List.keyreplace(chunks, ~c"Code", 0, {~c"Code", code <> <<0>>})) == original
    end

    test "argus's code is every argus beam, debug info included" do
      ebin = Path.join(to_string(:code.lib_dir(:panoptes)), "ebin")
      assert Scry.Fingerprint.argus_code() == Scry.Fingerprint.code_digest(ebin, debug_info: true)
      refute Scry.Fingerprint.argus_code() == Scry.Fingerprint.code_digest(ebin)
    end
  end

  describe "env/1" do
    test "carries the runtime, scry's code and argus's schema, and no argus code" do
      env = Scry.Fingerprint.env()
      assert env.scry_code =~ ~r/^[0-9a-f]{32}$/
      assert env.argus_schema == Argus.Schema.version()

      assert Map.keys(env) |> Enum.sort() ==
               [:argus_schema, :elixir, :otp, :scry, :scry_code, :specs_environment]
    end

    test "carries the applications the specs are read from, less argus's own beams" do
      # A read of argus's specs is keyed by `:argus_code` where it
      # happens; an argus edit must not move what every query reads.
      assert Scry.Fingerprint.env().specs_environment ==
               Argus.Specs.environment_digest(exclude: [:panoptes])
    end

    test "the applications the scan watches are named by version alone" do
      # Their beams move with every edit; the graph tracks each one.
      assert Scry.Fingerprint.env([:scry]).specs_environment ==
               Argus.Specs.environment_digest(exclude: [:panoptes, :scry])

      refute Scry.Fingerprint.env([:scry]).specs_environment ==
               Scry.Fingerprint.env().specs_environment
    end
  end

  describe "env/2 with a cache" do
    # A dependency outside OTP and Elixir, as Mix builds one: an
    # application directory whose ebin holds its .app file and a beam.
    defp fake_dependency!(dir) do
      ebin = Path.join(dir, "lib/scry_fake_dep/ebin")
      File.mkdir_p!(ebin)

      File.write!(
        Path.join(ebin, "scry_fake_dep.app"),
        ~s|{application, scry_fake_dep, [{vsn, "0.1.0"}, {modules, [scry_fake_dep]}]}.\n|
      )

      Path.join(ebin, "scry_fake_dep.beam")
    end

    # The dependency's one module, whose one function returns `value`:
    # atoms of one length compile to beams of one size.
    defp fake_beam(value) do
      forms = [
        {:attribute, 1, :module, :scry_fake_dep},
        {:attribute, 1, :export, [value: 0]},
        {:function, 1, :value, 0, [{:clause, 1, [], [], [{:atom, 1, value}]}]}
      ]

      {:ok, :scry_fake_dep, beam} = :compile.forms(forms, [:debug_info])
      beam
    end

    # Written in place (the inode stays) with `mtime`, well outside the
    # two seconds in which argus trusts no stamp.
    defp write_beam!(path, bytes, mtime) do
      File.write!(path, bytes)
      File.touch!(path, mtime)
    end

    # The specs environment a fresh VM — one that has hashed nothing —
    # computes with the dependency on its code path.
    defp fresh_specs_environment(ebin, opts) do
      peer = Peer.start!()

      try do
        Peer.run(peer, fn ->
          true = Code.prepend_path(ebin)
          Scry.Fingerprint.env([], opts).specs_environment
        end)
      after
        :peer.stop(peer)
      end
    end

    test "a dependency beam that changed moves the digest, as it does without one", %{
      tmp_dir: dir
    } do
      beam = fake_dependency!(dir)
      ebin = Path.dirname(beam)
      cache = [cache: Path.join(dir, "store")]
      now = System.os_time(:second)

      write_beam!(beam, fake_beam(:aaaa), now - 100)
      original = fresh_specs_environment(ebin, cache)
      assert File.ls!(Path.join(dir, "store/ebins")) != []
      assert fresh_specs_environment(ebin, cache) == original

      write_beam!(beam, fake_beam(:bbbb), now - 50)
      changed = fresh_specs_environment(ebin, cache)
      refute changed == original
      assert changed == fresh_specs_environment(ebin, [])
    end

    test "a beam rewritten under its old stamp keeps the kept hashes until a refresh", %{
      tmp_dir: dir
    } do
      beam = fake_dependency!(dir)
      ebin = Path.dirname(beam)
      cache = [cache: Path.join(dir, "store")]
      now = System.os_time(:second)

      write_beam!(beam, fake_beam(:aaaa), now - 100)
      %File.Stat{inode: inode, size: size} = File.stat!(beam)
      original = fresh_specs_environment(ebin, cache)

      # Other code, of the same size, in the same file, with its
      # modification time put back: every field of the stamp as it was.
      write_beam!(beam, fake_beam(:bbbb), now - 100)
      assert %File.Stat{inode: ^inode, size: ^size} = File.stat!(beam)
      rewritten = fresh_specs_environment(ebin, [])
      refute rewritten == original

      # The store answers for a stamp it knows without reading the beam:
      # the edge a stamp cannot see, as scry's scan cannot see a beam of
      # the same size and modification time.
      assert fresh_specs_environment(ebin, cache) == original

      # A refresh (`--force`) reads the beams again and keeps what it
      # read for the VMs after it.
      assert fresh_specs_environment(ebin, [refresh: true] ++ cache) == rewritten
      assert fresh_specs_environment(ebin, cache) == rewritten
    end

    test "keeps nothing with argus's stores turned off", %{tmp_dir: dir} do
      store = Path.join(dir, "store")
      peer = Peer.start!()

      # ARGUS_NO_CACHE is read from the environment: VM-wide, so in the peer.
      Peer.run(peer, fn ->
        System.put_env("ARGUS_NO_CACHE", "1")
        Scry.Fingerprint.env([], cache: store)
      end)

      refute File.exists?(store)
    end
  end

  describe "extraction_code/0" do
    test "covers every producer's code and the schema, and nothing only findings run" do
      {:ok, closure} = Scry.Fingerprint.extraction_closure()
      modules = Enum.map(closure, &elem(&1, 0))
      assert modules == Enum.sort(Enum.uniq(modules))

      for producer <- [:base | Scry.Analysis.all_extractors()] do
        {:ok, reached} = Argus.Cache.Code.closure(producer)
        assert reached -- closure == [], "#{inspect(producer)} runs code the digest leaves out"
      end

      schema =
        for module <- Application.spec(:panoptes, :modules),
            String.starts_with?(Atom.to_string(module), "Elixir.Argus.Schema."),
            do: module

      assert schema != []
      assert [Argus.Schema | schema] -- modules == []

      # What argus runs only to solve and to report: an edit to it
      # extracts nothing.
      outside =
        [Argus.Findings, Argus.Souffle, Argus.Cache.Code, Argus.Cache.Facts] ++
          Argus.Analysis.builtin_analysis_modules()

      assert Enum.filter(outside, &(&1 in modules)) == []
    end

    test "names the closure's code, not all of argus's" do
      digest = Scry.Fingerprint.extraction_code()
      assert digest =~ ~r/^[0-9a-f]{32}$/
      assert Scry.Fingerprint.extraction_code() == digest
      refute digest == Scry.Fingerprint.argus_code()
    end
  end
end
